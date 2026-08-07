// Body-based routing, partial-buffer variant.
//
// The point of this module is the one thing json_to_metadata and Lua cannot do:
// hold the request headers while inspecting only the FRONT of the body, then
// inject X-Gateway-Model-Name and let the rest of the body stream past.
//
//   on_http_request_headers -> Pause          (headers held, route not final)
//   on_http_request_body    -> feed new bytes to a streaming JSON parser
//                              found a TOP-LEVEL "model"? inject, resume
//                              not yet, more coming? Pause for the next chunk
//
// The parser is incremental and depth-aware, and both properties matter:
//
//   depth  - a substring scan for "model" happily matches a nested object, so
//            {"x":{"model":"b"},"model":"a"} routes as "b". The client controls
//            the whole body, so a decoy in front of the real key is trivial.
//   stream - parser state persists across callbacks, so each chunk is scanned
//            once rather than re-scanning the accumulated buffer every time.

use actson::feeder::PushJsonFeeder;
use actson::{JsonEvent, JsonParser};
use proxy_wasm::hostcalls::log;
use proxy_wasm::traits::*;
use proxy_wasm::types::*;

const HEADER: &str = "x-gateway-model-name";

/// Stop scanning after this much body.
///
/// The wasm VM shares the Envoy process, so anything it allocates counts
/// against the proxy's memory limit - and a streaming parser still has to
/// buffer the *current token*. A 30MiB prompt is one token, so scanning past
/// `model` into the message text costs ~the whole body, per concurrent request.
/// Measured: 24 concurrent 30MiB requests with `model` last OOMKilled a 1GiB
/// gateway (exit 137).
///
/// `model` sits in the first few hundred bytes of any real OpenAI request, so
/// this only gives up on pathological ones - and giving up means no header and
/// the default route, rather than taking the gateway down with it.
const MAX_SCAN_BYTES: usize = 256 * 1024;

proxy_wasm::main! {{
    proxy_wasm::set_log_level(LogLevel::Info);
    proxy_wasm::set_http_context(|_, _| -> Box<dyn HttpContext> {
        Box::new(ModelRouter::new())
    });
}}

struct ModelRouter {
    scanner: Scanner,
    /// Bytes already handed to the parser, so each chunk is fed exactly once.
    fed: usize,
    finished: bool,
}

impl ModelRouter {
    fn new() -> Self {
        Self { scanner: Scanner::new(), fed: 0, finished: true }
    }
}

impl Context for ModelRouter {}

impl HttpContext for ModelRouter {
    fn on_http_request_headers(&mut self, _: usize, end_of_stream: bool) -> Action {
        // A client must never supply this itself, and the route was already
        // resolved from the original headers - so drop it and force a re-match
        // either way.
        self.set_http_request_header(HEADER, None);
        clear_route_cache(self);

        let json = self
            .get_http_request_header("content-type")
            .map(|ct| ct.contains("application/json"))
            .unwrap_or(false);

        if end_of_stream || !json {
            return Action::Continue;
        }

        // Hold the headers. This is the bit Lua's bodyChunks() cannot do.
        self.finished = false;
        Action::Pause
    }

    fn on_http_request_body(&mut self, body_size: usize, end_of_stream: bool) -> Action {
        if self.finished {
            return Action::Continue;
        }

        // Envoy accumulates while we pause, so body_size is the total buffered
        // so far. Only the tail is new.
        if body_size > self.fed {
            let chunk = self
                .get_http_request_body(self.fed, body_size - self.fed)
                .unwrap_or_default();
            self.fed = body_size;
            match self.scanner.feed(&chunk, end_of_stream) {
                Outcome::Found(model) => {
                    let _ = log(LogLevel::Info, &format!("model={} after {}B", model, self.fed));
                    self.set_http_request_header(HEADER, Some(&model));
                    clear_route_cache(self);
                    self.finished = true;
                    return Action::Continue;
                }
                Outcome::Done | Outcome::Invalid => {
                    // Valid JSON with no top-level "model", or not JSON at all.
                    // Either way there is nothing to inject; let it through.
                    self.finished = true;
                    return Action::Continue;
                }
                Outcome::NeedMore => {
                    if self.fed >= MAX_SCAN_BYTES {
                        let _ = log(
                            LogLevel::Info,
                            &format!("no top-level model in first {}B, giving up", self.fed),
                        );
                        self.finished = true;
                        return Action::Continue;
                    }
                }
            }
        }

        if end_of_stream {
            self.finished = true;
            return Action::Continue;
        }

        // Not found yet and more is coming. Only the bytes seen so far are held.
        Action::Pause
    }
}

/// The Rust SDK exposes no route-cache API; Envoy registers it as a Wasm
/// foreign function instead (see source/extensions/common/wasm/foreign.cc).
/// Without this the router keeps the route it resolved from the original
/// headers and the injected value steers nothing.
fn clear_route_cache(ctx: &dyn Context) {
    let _ = ctx.call_foreign_function("clear_route_cache", None);
}

enum Outcome {
    Found(String),
    /// Document ended without a top-level "model".
    Done,
    /// Malformed JSON. Not our problem - the backend can reject it.
    Invalid,
    NeedMore,
}

/// Incremental scan for a top-level `"model"` string value.
struct Scanner {
    parser: JsonParser<PushJsonFeeder>,
    depth: usize,
    /// The last field name seen was a top-level `model`, so the next value is ours.
    want_value: bool,
}

impl Scanner {
    fn new() -> Self {
        Self { parser: JsonParser::new(PushJsonFeeder::new()), depth: 0, want_value: false }
    }

    fn feed(&mut self, new: &[u8], last: bool) -> Outcome {
        let mut i = 0;
        loop {
            match self.parser.next_event() {
                Ok(None) => return Outcome::Done,
                Ok(Some(JsonEvent::NeedMoreInput)) => {
                    if i < new.len() {
                        i += self.parser.feeder.push_bytes(&new[i..]);
                    } else if last {
                        self.parser.feeder.done();
                    } else {
                        return Outcome::NeedMore;
                    }
                }
                Ok(Some(JsonEvent::StartObject)) | Ok(Some(JsonEvent::StartArray)) => {
                    self.depth += 1;
                    // {"model":["a"]} must not yield "a".
                    self.want_value = false;
                }
                Ok(Some(JsonEvent::EndObject)) | Ok(Some(JsonEvent::EndArray)) => {
                    self.depth = self.depth.saturating_sub(1);
                    self.want_value = false;
                }
                Ok(Some(JsonEvent::FieldName)) => {
                    self.want_value = self.depth == 1
                        && matches!(self.parser.current_str(), Ok("model"));
                }
                Ok(Some(JsonEvent::ValueString)) => {
                    if self.want_value {
                        if let Ok(s) = self.parser.current_str() {
                            return Outcome::Found(s.to_string());
                        }
                    }
                    self.want_value = false;
                }
                Ok(Some(_)) => self.want_value = false,
                Err(_) => return Outcome::Invalid,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Outcome, Scanner};

    /// Feed a whole document in one go.
    fn scan(body: &str) -> Option<String> {
        match Scanner::new().feed(body.as_bytes(), true) {
            Outcome::Found(m) => Some(m),
            _ => None,
        }
    }

    /// Feed a document one byte at a time, proving the parser resumes correctly
    /// across chunk boundaries however unkindly they fall.
    fn scan_bytewise(body: &str) -> Option<String> {
        let mut s = Scanner::new();
        let bytes = body.as_bytes();
        for (i, b) in bytes.iter().enumerate() {
            let last = i == bytes.len() - 1;
            if let Outcome::Found(m) = s.feed(&[*b], last) {
                return Some(m);
            }
        }
        None
    }

    #[test]
    fn extracts_top_level_model() {
        for body in [
            r#"{"model":"llama-3-8b","messages":[]}"#,
            r#"{"stream":true, "model" : "m-7b" }"#,
            r#"{"messages":[{"role":"user","content":"hi"}],"model":"trailing"}"#,
        ] {
            assert!(scan(body).is_some(), "{body}");
            assert_eq!(scan(body), scan_bytewise(body), "chunking changed the answer: {body}");
        }
        assert_eq!(scan(r#"{"model":"llama-3-8b","messages":[]}"#).as_deref(), Some("llama-3-8b"));
    }

    #[test]
    fn ignores_nested_model_keys() {
        // The attack: a decoy nested object in front of the real key. A
        // substring scan returns "decoy" for all of these.
        let cases = [
            (r#"{"x":{"model":"decoy"},"model":"real"}"#, Some("real")),
            (r#"{"tools":[{"function":{"model":"decoy"}}]}"#, None),
            (r#"{"messages":[{"model":"decoy"}],"model":"real"}"#, Some("real")),
            (r#"{"a":{"b":{"model":"decoy"}}}"#, None),
        ];
        for (body, want) in cases {
            assert_eq!(scan(body).as_deref(), want, "{body}");
            assert_eq!(scan_bytewise(body).as_deref(), want, "bytewise: {body}");
        }
    }

    #[test]
    fn model_must_be_a_string() {
        assert_eq!(scan(r#"{"model":123}"#), None);
        assert_eq!(scan(r#"{"model":null}"#), None);
        assert_eq!(scan(r#"{"model":["a"]}"#), None);
        assert_eq!(scan(r#"{"model":{"name":"a"}}"#), None);
    }

    #[test]
    fn no_model_and_malformed() {
        assert_eq!(scan(r#"{"messages":[]}"#), None);
        assert_eq!(scan(r#"{"model":"#), None);
        assert_eq!(scan("not json at all"), None);
        assert_eq!(scan(""), None);
    }

    #[test]
    fn waits_rather_than_truncating() {
        // Cut mid-value: must not report a half model name.
        let mut s = Scanner::new();
        assert!(matches!(s.feed(br#"{"model":"llama-3"#, false), Outcome::NeedMore));
        match s.feed(br#"-8b","messages":[]}"#, true) {
            Outcome::Found(m) => assert_eq!(m, "llama-3-8b"),
            _ => panic!("expected the full model name once the rest arrived"),
        }
    }

    #[test]
    fn escapes_in_prompt_text_are_not_keys() {
        let body = r#"{"messages":[{"role":"user","content":"{\"model\":\"decoy\"}"}],"model":"real"}"#;
        assert_eq!(scan(body).as_deref(), Some("real"));
        assert_eq!(scan_bytewise(body).as_deref(), Some("real"));
    }
}

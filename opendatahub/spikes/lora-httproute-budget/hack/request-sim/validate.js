// Replay every recorded probe through the matcher. Any disagreement is a bug in
// the matcher, not in the golden file.
const fs = require("fs");
const path = require("path");
const gw = require("./matcher.js").gw;

const REPO = "/home/bartek/code/work/playground/opendatahub/spikes/lora-httproute-budget";
const routes = JSON.parse(fs.readFileSync(path.join(__dirname, "routes.json"), "utf8"));
const SHAPES = ["current", "split", "split-noslash", "alternation", "nested"];

let total = 0, bad = 0;
const failures = [];
for (const shape of SHAPES) {
  const lines = fs.readFileSync(path.join(REPO, "golden", shape + ".tsv"), "utf8").split("\n");
  for (const ln of lines) {
    if (!ln.trim() || ln.startsWith("#")) continue;
    const f = ln.split(/\s+/);
    const [, method, p, hdr, , expected] = f;
    const headers = hdr === "-" ? {} : { "x-gateway-model-name": hdr };
    const got = gw.evaluate(routes[shape], { method, path: p, headers });
    const dest = got.winner ? got.winner.dest : "(none)";
    total++;
    if (dest !== expected) {
      bad++;
      if (failures.length < 12) failures.push({ shape, method, p, hdr, expected, dest,
        rule: got.winner && got.winner.routeKey + " " + got.winner.ruleName });
    }
  }
}
console.log(`${total - bad}/${total} outcomes reproduced`);
if (bad) { console.log("FAILURES:"); failures.forEach(x => console.log("  ", JSON.stringify(x))); process.exit(1); }

// Cross-check against a measurement the golden files above do not cover: probed
// live in probe-authz-split.sh, where a publisher path carrying ANOTHER tenant's
// model header stayed on svc-a. Different harness, real backends, same answer.
const Q = "publishers/lora-budget/models/";
const inv = [
  ["a publisher path outranks a header naming another service",
   { method: "POST", path: "/publishers/lora-budget/models/model-a/v1/chat/completions",
     headers: { "x-gateway-model-name": Q + "model-b" } },
   "lora-budget/svc-a-kserve-route"],
  ["the shared endpoint does not resolve without the header",
   { method: "POST", path: "/v1/chat/completions", headers: {} },
   "lora-budget/neighbour"],
  ["the shared endpoint resolves with an adapter header",
   { method: "POST", path: "/v1/chat/completions", headers: { "x-gateway-model-name": Q + "adapter-a1" } },
   "lora-budget/svc-a-kserve-route"],
];
let ibad = 0;
for (const [name, req, wantRoute] of inv) {
  const w = gw.evaluate(routes.current, req).winner;
  const got = w ? w.routeKey : "(none)";
  const ok = got === wantRoute;
  if (!ok) ibad++;
  console.log(`  ${ok ? "ok  " : "FAIL"}  ${name}  -> ${got}${w ? " " + w.ruleName : ""}`);
}
if (ibad) process.exit(1);

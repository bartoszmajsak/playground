const fs = require("fs"), path = require("path");
const gw = require("./matcher.js").gw;
const R = JSON.parse(fs.readFileSync(path.join(__dirname, "routes.json"), "utf8"));
const Q = "publishers/lora-budget/models/";
const SH = ["current", "split", "split-noslash", "alternation", "nested"];
const P = [
  ["the shared endpoint", "POST", "/v1/chat/completions", Q + "adapter-a1"],
  ["same, no header", "POST", "/v1/chat/completions", ""],
  ["trailing slash", "POST", "/v1/completions/", Q + "model-a"],
  ["health, with a header", "GET", "/health", Q + "model-a"],
  ["publisher path", "POST", "/publishers/lora-budget/models/model-a/v1/chat/completions", ""],
  ["a nested adapter name", "POST", "/v1/chat/completions", Q + "model-a/adapters/sql-generation"],
  ["a neighbour's model", "POST", "/v1/chat/completions", Q + "model-a-instruct"],
  ["an adapter that does not exist", "POST", "/v1/chat/completions", Q + "adapter-a9"],
  ["free-form path", "DELETE", "/v1/responses/resp_x/cancel", Q + "adapter-a2"],
  ["empty path", "GET", "", ""],
  ["regex-hostile header", "POST", "/v1/chat/completions", "a(b"],
];
const TIER = ["PathPrefix", "RegularExpression", "Exact"];
let width = Math.max(...P.map(p => p[0].length));
console.log("preset".padEnd(width), SH.map(s => s.padEnd(15)).join(""));
for (const [name, method, p, hdr] of P) {
  const cells = SH.map(s => {
    const w = gw.evaluate(R[s], { method, path: p, headers: { "x-gateway-model-name": hdr } }).winner;
    return (w ? { "echo-pool": "pool", "echo-service": "service", "echo-neighbour": "falls-through" }[w.dest] : "NO MATCH").padEnd(15);
  });
  console.log(name.padEnd(width), cells.join(""));
}
console.log("\nthe nested claim in the prose:");
for (const s of ["current", "nested"]) {
  const w = gw.evaluate(R[s], { method: "POST", path: "/v1/chat/completions",
    headers: { "x-gateway-model-name": Q + "model-a/adapters/anything-at-all" } }).winner;
  console.log(" ", s.padEnd(12), w ? `${w.dest}  via ${w.ruleName}  (${TIER[w.tier]}, ${w.chars} chars, ${w.headers} hdr)` : "NO MATCH");
}

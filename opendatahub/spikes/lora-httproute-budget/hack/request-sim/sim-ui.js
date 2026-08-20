(function () {
  var ROUTES = window.SIM_ROUTES, gw = window.SIM.gw;
  if (!ROUTES || !gw) return;

  var Q = "publishers/lora-budget/models/";
  var MAIN = "lora-budget/svc-a-kserve-route";
  var DEST = {
    "echo-pool":      ["InferencePool", "pool", "through the endpoint picker"],
    "echo-service":   ["workload Service", "svc", "straight to vLLM, no scheduler"],
    "echo-neighbour": ["falls through", "nbr", "no rule in this route matched, so another route on the gateway answered"],
  };
  var WHY = {
    "path": "path", "method": "method", "header-value": "header value", "header-absent": "no header",
  };
  var PRESETS = [
    ["the shared endpoint", "POST", "/v1/chat/completions", Q + "adapter-a1"],
    ["same, no header", "POST", "/v1/chat/completions", ""],
    ["trailing slash", "POST", "/v1/completions/", Q + "model-a"],
    ["health, with a header", "GET", "/health", Q + "model-a"],
    ["publisher path", "POST", "/publishers/lora-budget/models/model-a/v1/chat/completions", ""],
    ["a nested adapter name", "POST", "/v1/chat/completions", Q + "model-a/adapters/sql-generation"],
    ["a neighbour's model", "POST", "/v1/chat/completions", Q + "model-a-instruct"],
    ["an adapter that does not exist", "POST", "/v1/chat/completions", Q + "adapter-a9"],
  ];

  var shape = "current", timers = [];
  var $ = function (id) { return document.getElementById(id); };
  var reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  var pres = $("simPresets");
  PRESETS.forEach(function (p) {
    var b = document.createElement("button");
    b.type = "button";
    b.textContent = p[0];
    b.addEventListener("click", function () {
      $("simMethod").value = p[1]; $("simPath").value = p[2]; $("simHdr").value = p[3];
      run();
    });
    pres.appendChild(b);
  });

  Array.prototype.forEach.call(document.querySelectorAll(".sim-shapes .sh"), function (b) {
    b.addEventListener("click", function () {
      shape = b.dataset.sh;
      Array.prototype.forEach.call(document.querySelectorAll(".sim-shapes .sh"), function (o) {
        var on = o === b;
        o.classList.toggle("on", on);
        o.setAttribute("aria-pressed", on ? "true" : "false");
      });
      run();
    });
  });
  ["simMethod", "simPath", "simHdr"].forEach(function (id) {
    $(id).addEventListener("input", run);
    $(id).addEventListener("change", run);
  });

  function esc(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  function describe(m) {
    var bits = [];
    if (m[0]) bits.push(m[0][0] + " " + m[0][1]);
    m[1].forEach(function (h) { bits.push(h[0] + " " + h[1] + "=" + h[2]); });
    if (m[2]) bits.push("method " + m[2]);
    return bits.join("  |  ");
  }

  function run() {
    timers.forEach(clearTimeout); timers = [];
    var routes = ROUTES[shape];
    var req = {
      method: $("simMethod").value,
      path: $("simPath").value || "/",
      headers: { "x-gateway-model-name": $("simHdr").value },
    };
    var res = gw.evaluate(routes, req);
    var win = res.winner;

    // rules of the service this report is about; other routes are summarised beside it
    var mine = res.trace.filter(function (t) { return t.routeKey === MAIN; });
    var host = $("simRules");
    host.innerHTML = mine.map(function (t) {
      var verdict = t.hit
        ? "match " + (t.matchIdx + 1) + " of " + t.matches
        : "no " + (WHY[t.why] || "match");
      return '<div class="rr" data-i="' + t.ruleIdx + '">'
           + '<span class="ri">' + t.ruleIdx + "</span>"
           + '<span class="rn">' + esc(t.ruleName || "(unnamed)") + "</span>"
           + '<span class="rv">' + verdict + "</span></div>";
    }).join("");

    var rows = host.querySelectorAll(".rr");
    function settle(i) {
      var t = mine[i], el = rows[i];
      el.classList.add("done", t.hit ? "hit" : "miss");
      if (win && win.routeKey === MAIN && win.ruleIdx === t.ruleIdx) el.classList.add("win");
    }
    if (reduce) {
      for (var i = 0; i < rows.length; i++) settle(i);
      reveal();
    } else {
      for (var j = 0; j < rows.length; j++) {
        (function (k) { timers.push(setTimeout(function () { settle(k); }, 40 * k)); })(j);
      }
      timers.push(setTimeout(reveal, 40 * rows.length + 80));
    }

    function reveal() {
      var d = $("simDest");
      var info = win ? DEST[win.dest] : ["nothing matched", "nbr", "no route on the gateway claimed this request"];
      d.className = "sim-dest " + info[1];
      d.innerHTML = '<span class="dl">lands on</span><span class="dv">' + info[0] + "</span>"
                  + '<span class="dh">' + info[2] + "</span>";

      var why = $("simWhy");
      if (!win) {
        why.innerHTML = "";
      } else {
        var tier = ["PathPrefix", "RegularExpression", "Exact"][win.tier] || "any path";
        why.innerHTML = "<b>" + esc(win.ruleName) + "</b> won on <b>" + tier + "</b>, "
          + win.chars + " matching characters, " + win.headers
          + (win.headers === 1 ? " header match" : " header matches")
          + (win.routeKey === MAIN ? "" : ", on <b>" + esc(win.routeKey) + "</b>")
          + ".<br><code>" + esc(describe(win.match)) + "</code>";
      }

      var others = res.trace.filter(function (t) { return t.routeKey !== MAIN && t.hit; });
      $("simOthers").innerHTML = others.length
        ? '<span class="o">matched on other routes:</span>' + others.map(function (t) {
            var isWin = win && win.routeKey === t.routeKey && win.ruleIdx === t.ruleIdx;
            return '<span class="o">&nbsp;&nbsp;' + esc(t.routeKey) + " &middot; " + esc(t.ruleName)
                 + (isWin ? "  &larr; won" : "") + "</span>";
          }).join("")
        : "";

      var hits = res.trace.filter(function (t) { return t.hit; }).length;
      $("simNote").textContent = hits + (hits === 1 ? " rule matched" : " rules matched")
        + " across " + routes.length + " routes on this gateway; the most specific one wins.";
    }
  }

  $("simRouteName").textContent = MAIN;
  run();
})();

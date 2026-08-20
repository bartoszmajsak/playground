/* Gateway API HTTPRoute matching, enough of it to answer "where does this land".
 *
 * Not a guess at the spec: validated against all 72 recorded probes on all five
 * shapes (360 outcomes) by sim/validate.js. If it disagrees with a golden file
 * anywhere, it is wrong and the report should not ship it.
 *
 * Ranking, per gateway.networking.k8s.io v1 HTTPRouteRule:
 *   path type (Exact > RegularExpression > PathPrefix), then characters in the
 *   matching path, then header match count, then query param count. Ties across
 *   routes fall back to the route key, then rule order, then match order.
 */
(function (root) {
  function pathHit(pm, path) {
    if (!pm) return { ok: true, tier: -1, chars: 0 };
    var type = pm[0], value = pm[1];
    if (type === "Exact") return { ok: path === value, tier: 2, chars: value.length };
    if (type === "RegularExpression") {
      var re;
      try { re = new RegExp("^(?:" + value + ")$"); } catch (e) { return { ok: false, tier: 1, chars: 0 }; }
      return { ok: re.test(path), tier: 1, chars: value.length };
    }
    // PathPrefix matches whole path segments, so /abc covers /abc and /abc/d but not /abcd
    var v = value.replace(/\/+$/, "");
    var ok = v === "" || path === v || path.indexOf(v + "/") === 0;
    return { ok: ok, tier: 0, chars: (v === "" ? 1 : v.length) };
  }

  function headerHit(hm, headers) {
    var got = headers[hm[0]];
    if (got === undefined || got === null || got === "") return false;
    if (hm[1] === "RegularExpression") {
      var re;
      try { re = new RegExp("^(?:" + hm[2] + ")$"); } catch (e) { return false; }
      return re.test(got);
    }
    return got === hm[2];
  }

  // Why a match failed, for the trace. Path is checked first because that is the
  // question a reader asks first.
  function tryMatch(m, req) {
    var p = pathHit(m[0], req.path);
    if (!p.ok) return { ok: false, why: "path" };
    if (m[2] && m[2] !== req.method) return { ok: false, why: "method" };
    for (var i = 0; i < m[1].length; i++) {
      if (!headerHit(m[1][i], req.headers)) {
        return { ok: false, why: req.headers[m[1][i][0]] ? "header-value" : "header-absent" };
      }
    }
    return { ok: true, tier: p.tier, chars: p.chars, headers: m[1].length };
  }

  function better(a, b) {
    if (a.tier !== b.tier) return a.tier > b.tier;
    if (a.chars !== b.chars) return a.chars > b.chars;
    if (a.headers !== b.headers) return a.headers > b.headers;
    if (a.routeKey !== b.routeKey) return a.routeKey < b.routeKey;
    if (a.ruleIdx !== b.ruleIdx) return a.ruleIdx < b.ruleIdx;
    return a.matchIdx < b.matchIdx;
  }

  function evaluate(routes, req) {
    var headers = {};
    for (var k in req.headers) {
      if (req.headers[k]) headers[k.toLowerCase()] = req.headers[k];
    }
    var r = { method: req.method || "POST", path: req.path || "/", headers: headers };

    var winner = null, trace = [];
    for (var ri = 0; ri < routes.length; ri++) {
      var rt = routes[ri];
      for (var ui = 0; ui < rt.rules.length; ui++) {
        var rule = rt.rules[ui], best = null, why = null;
        for (var mi = 0; mi < rule.m.length; mi++) {
          var res = tryMatch(rule.m[mi], r);
          if (!res.ok) { if (!why) why = res.why; continue; }
          var cand = {
            tier: res.tier, chars: res.chars, headers: res.headers,
            routeKey: rt.r, ruleIdx: ui, ruleName: rule.n, matchIdx: mi,
            dest: rule.to, match: rule.m[mi],
          };
          if (!best || better(cand, best)) best = cand;
        }
        trace.push({
          routeKey: rt.r, ruleIdx: ui, ruleName: rule.n, dest: rule.to,
          matches: rule.m.length, hit: !!best, why: best ? null : why,
          matchIdx: best ? best.matchIdx : -1,
        });
        if (best && (!winner || better(best, winner))) winner = best;
      }
    }
    return { winner: winner, trace: trace };
  }

  root.gw = { evaluate: evaluate, tryMatch: tryMatch, pathHit: pathHit };
})(typeof module !== "undefined" && module.exports ? module.exports : (window.SIM = window.SIM || {}));

# request simulator

The report's *Try a request* section evaluates Gateway API matching in the browser
instead of replaying a lookup table, so an arbitrary path and header can be
answered. These are its sources.

| file | what it is |
|---|---|
| `extract.py` | pulls each shape's rules out of `make-shape.py` into `routes.json`, so the simulator cannot drift from the synthesis that produced every golden file. Includes the neighbour route, because "falls through" is one of the outcomes |
| `matcher.js` | Gateway API precedence: path type, then characters in the matching path, then header count. Runs unchanged in node and in the page |
| `validate.js` | replays all 72 probes on all 5 shapes and compares against `golden/*.tsv`, plus three invariants measured separately on the live cluster |
| `sim-ui.js` | the page's controls, rule trace and animation |
| `smoke.js` | prints where each preset lands on each shape, including the deliberately hostile inputs |

`assemble.py` runs `extract.py` and `validate.js` before it writes `report.html`,
so a matcher that disagrees with a golden file fails the build rather than
shipping.

```
python3 hack/request-sim/extract.py     # writes routes.json
node hack/request-sim/validate.js       # 360/360 plus the invariants
node hack/request-sim/smoke.js          # preset x shape table
```

# Resource glyphs

The Kubernetes kinds in `report.html` use the **upstream** icons from
[kubernetes/community](https://github.com/kubernetes/community/tree/master/icons),
CC BY 4.0. They are embedded rather than linked because the artifact CSP blocks
external requests.

```
curl -sfLO https://raw.githubusercontent.com/kubernetes/community/master/icons/svg/resources/unlabeled/{pod,svc,crd,ing,ep}.svg
python3 convert.py     # -> symbols.html
python3 custom.py      # -> custom.html
```

`convert.py` strips the Inkscape metadata (each published file is 5-10 KB of
editor cruft around a few hundred bytes of geometry), keeps every path and
transform verbatim, and rewrites the hexagon to `currentColor` so a badge can
recolour it per context while the white pictogram stays white. Path counts are
asserted before and after.

`custom.py` draws the four kinds with no upstream icon - InferencePool,
AuthPolicy, HTTPRoute and the vLLM workload - on the same point-up hexagon so a
row of badges reads as one family.

Interface marks (clock, grid, warning) stay flat line art on purpose: they are
not Kubernetes kinds and should not wear the hexagon.

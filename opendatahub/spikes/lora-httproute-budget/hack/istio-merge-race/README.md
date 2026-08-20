# istio mergeHTTPRoutes data race

Standalone reproducer for the crash that disrupted this spike (FINDINGS 27):

```
fatal error: concurrent map writes
istio.io/istio/pilot/pkg/config/kube/gateway.mergeHTTPRoutes.func2
    pilot/pkg/config/kube/gateway/route_collections.go:868
```

`merge_test.go` is a faithful reduction of `route_collections.go:825-880` at
istio 1.30.3, with everything unrelated to the map handling stripped.

```
go test -run TestAliasingEscapes ./...   # deterministic, no -race needed
go test -race -run TestConcurrentMerge ./...
```

The first fails without concurrency: the merged result shares a map with its
input. The second reports `WARNING: DATA RACE` on the line corresponding to
`route_collections.go:868`.

See `../../FINDINGS.md` section 27 for how it was hit on a live cluster and what
does *not* trigger it (normal LoRA adapter management: one route write per add or
remove, zero at rest).

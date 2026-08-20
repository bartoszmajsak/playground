// Minimal reproducer for the data race in istio's mergeHTTPRoutes.
//
// pilot/pkg/config/kube/gateway/route_collections.go, istio 1.30.3.
//
// merge() below is a faithful reduction of lines 825-880: same defensive copy of
// the base map, same merge loop, same fallback branch. Everything unrelated to
// the map handling is stripped.
//
//	go test -race ./...
package repro

import (
	"sync"
	"testing"
)

// stands in for kube.InferencePoolRouteRuleConfig
type poolCfg struct{ name string }

const ipKey = "inference-pool-configs" // constants.ConfigExtraPerRouteRuleInferencePoolConfigs

type conf struct {
	Extra map[string]any
}

// shallow, like config.Config.DeepCopy() is for the Extra field: the map header
// is copied, the map it points at is not.
func (c conf) shallowCopy() conf {
	e := make(map[string]any, len(c.Extra))
	for k, v := range c.Extra {
		e[k] = v
	}
	return conf{Extra: e}
}

// merge reproduces route_collections.go:825-880.
func merge(configs []conf) conf {
	base := configs[0].shallowCopy()

	// :826-838 - defensive deep copy, but ONLY of configs[0]'s map.
	if base.Extra != nil {
		if ip, ok := base.Extra[ipKey].(map[string]poolCfg); ok {
			cp := make(map[string]poolCfg, len(ip))
			for k, v := range ip {
				cp[k] = v
			}
			base.Extra[ipKey] = cp
		}
	}

	for _, c := range configs[1:] {
		if base.Extra == nil && c.Extra != nil {
			base.Extra = make(map[string]any)
		}
		if c.Extra == nil {
			continue
		}
		for k, v := range c.Extra {
			if k != ipKey {
				if _, exists := base.Extra[k]; !exists {
					base.Extra[k] = v
				}
				continue
			}
			baseMap, baseOk := base.Extra[k].(map[string]poolCfg) // :861
			cfgMap, cfgOk := v.(map[string]poolCfg)               // :862
			if baseOk && cfgOk {
				for rn, rc := range cfgMap {
					baseMap[rn] = rc // :868  <-- the write that panics
				}
			} else if cfgOk {
				if _, exists := base.Extra[k]; !exists {
					base.Extra[k] = v // :873  <-- ALIASES the other config's map
				}
			}
		}
	}
	return base
}

// The shape that triggers it: several HTTPRoutes merging onto one key, where the
// OLDEST (configs[0], after sortRoutesByCreationTime) carries no InferencePool
// and at least two later ones do.
func inputs() []conf {
	return []conf{
		{Extra: map[string]any{}}, // oldest: a plain route, no InferencePool
		{Extra: map[string]any{ipKey: map[string]poolCfg{"svc-a/v1-model-routing": {"svc-a"}}}},
		{Extra: map[string]any{ipKey: map[string]poolCfg{"svc-b/v1-model-routing": {"svc-b"}}}},
	}
}

// TestAliasingEscapes is deterministic and needs no -race: it shows the merged
// result shares a map with its INPUT, which is cached krt state owned by another
// collection entry. Everything else follows from that.
func TestAliasingEscapes(t *testing.T) {
	in := inputs()
	got := merge(in)

	merged := got.Extra[ipKey].(map[string]poolCfg)
	source := in[1].Extra[ipKey].(map[string]poolCfg)

	if len(source) != 1 {
		t.Fatalf("input config was mutated by merge: got %d entries, want 1: %v", len(source), source)
	}
	if &merged == &source {
		t.Log("same header")
	}
	// prove they are the same map, not equal copies
	merged["probe"] = poolCfg{"written-via-result"}
	if _, leaked := source["probe"]; leaked {
		t.Fatalf("ALIASED: writing to the merge result mutated input config[1]'s map. "+
			"route_collections.go:873 stores the map by reference; :868 then writes through it. source=%v", source)
	}
}

// TestConcurrentMerge is the crash. Two goroutines merge two different keys that
// both include the same underlying map - exactly what krt does when it runs the
// transform for several index keys in parallel.
//
//	fatal error: concurrent map writes
func TestConcurrentMerge(t *testing.T) {
	shared := map[string]poolCfg{"svc-a/v1-model-routing": {"svc-a"}}

	key := func(extra string) []conf {
		return []conf{
			{Extra: map[string]any{}},
			{Extra: map[string]any{ipKey: shared}}, // the SAME map, as krt caches it
			{Extra: map[string]any{ipKey: map[string]poolCfg{extra: {extra}}}},
		}
	}

	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			for n := 0; n < 500; n++ {
				merge(key(string(rune('a'+i)) + "/v1-model-routing"))
			}
		}(i)
	}
	wg.Wait()
}

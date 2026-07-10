package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"sync/atomic"
	"syscall"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/rest"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// --- CRD types (minimal, no codegen needed) ---

var (
	SchemeGroupVersion = schema.GroupVersion{Group: "spike.example.io", Version: "v1alpha1"}
	SchemeBuilder      = runtime.NewSchemeBuilder(func(s *runtime.Scheme) error {
		s.AddKnownTypes(SchemeGroupVersion, &Model{}, &ModelList{})
		metav1.AddToGroupVersion(s, SchemeGroupVersion)
		return nil
	})
)

type Model struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec              ModelSpec `json:"spec,omitempty"`
}

type ModelSpec struct {
	DisplayName string `json:"displayName,omitempty"`
	Provider    string `json:"provider,omitempty"`
}

type ModelList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []Model `json:"items"`
}

func (m *Model) DeepCopyObject() runtime.Object {
	cp := *m
	return &cp
}

func (ml *ModelList) DeepCopyObject() runtime.Object {
	cp := *ml
	cp.Items = make([]Model, len(ml.Items))
	copy(cp.Items, ml.Items)
	return &cp
}

// --- Server ---

func main() {
	scheme := runtime.NewScheme()
	if err := SchemeBuilder.AddToScheme(scheme); err != nil {
		slog.Error("scheme registration failed", "error", err)
		os.Exit(1)
	}

	restCfg := ctrl.GetConfigOrDie()
	useCache := os.Getenv("USE_CACHE") == "true"

	var apiCalls atomic.Int64
	restCfg.Wrap(func(rt http.RoundTripper) http.RoundTripper {
		return roundTripperFunc(func(r *http.Request) (*http.Response, error) {
			apiCalls.Add(1)
			return rt.RoundTrip(r)
		})
	})

	cli, cleanup, err := buildClient(restCfg, scheme, useCache)
	defer cleanup()
	if err != nil {
		slog.Error("failed to create client", "error", err)
		os.Exit(1)
	}

	mode := "direct"
	if useCache {
		mode = "cached (informer-backed)"
	}
	addr := os.Getenv("ADDR")
	if addr == "" {
		addr = ":8080"
	}
	slog.Info("starting server", "mode", mode, "addr", addr)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/models", modelsHandler(cli, &apiCalls))

	srv := &http.Server{Addr: addr, Handler: mux}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	go func() {
		<-ctx.Done()
		srv.Shutdown(context.Background())
	}()

	if err := srv.ListenAndServe(); err != http.ErrServerClosed {
		slog.Error("server error", "error", err)
		os.Exit(1)
	}
}

// modelsHandler is identical regardless of client mode.
// It calls cli.List — the caching is transparent.
func modelsHandler(cli client.Reader, apiCalls *atomic.Int64) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		before := apiCalls.Load()

		var list ModelList
		if err := cli.List(r.Context(), &list); err != nil {
			http.Error(w, fmt.Sprintf("list models: %v", err), http.StatusInternalServerError)
			return
		}

		sort.Slice(list.Items, func(i, j int) bool {
			return list.Items[i].CreationTimestamp.Before(&list.Items[j].CreationTimestamp)
		})

		after := apiCalls.Load()
		slog.Info("served request", "models", len(list.Items), "apiServerCalls", after-before)

		type modelResponse struct {
			Name     string `json:"name"`
			Provider string `json:"provider"`
		}
		out := make([]modelResponse, len(list.Items))
		for i, m := range list.Items {
			out[i] = modelResponse{Name: m.Spec.DisplayName, Provider: m.Spec.Provider}
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"models": out})
	}
}

type roundTripperFunc func(*http.Request) (*http.Response, error)

func (f roundTripperFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func buildClient(restCfg *rest.Config, scheme *runtime.Scheme, useCache bool) (client.Reader, func(), error) {
	noop := func() {}
	if !useCache {
		cli, err := client.New(restCfg, client.Options{Scheme: scheme})
		return cli, noop, err
	}

	// Cached client — same List call, backed by informers.
	// No watches, no reconciler, no controller. Just a different constructor.
	c, err := cache.New(restCfg, cache.Options{Scheme: scheme})
	if err != nil {
		return nil, noop, fmt.Errorf("create cache: %w", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		if err := c.Start(ctx); err != nil {
			slog.Error("cache stopped", "error", err)
		}
	}()
	if !c.WaitForCacheSync(ctx) {
		cancel()
		return nil, noop, fmt.Errorf("cache sync failed")
	}

	return c, cancel, nil
}

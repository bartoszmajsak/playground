# Transparent caching with controller-runtime client

This spike demonstrates that controller-runtime's informer-backed cache is a transparent implementation detail of the client constructor, equally usable in plain HTTP services as in controllers.

## Run

```bash
./setup.sh      # kind cluster + CRD
./validate.sh   # seeds data, runs both modes, adds/deletes models, tests replicas
```

## What it proves

The server exposes `GET /v1/models` listing custom resources. Two modes via `USE_CACHE` env var:

| Mode | Client constructor | API calls per request |
|------|-------------------|----------------------|
| `USE_CACHE=false` | `client.New` (direct) | 1 |
| `USE_CACHE=true` | `cache.New` (informer-backed) | 0 |

A round-tripper counter logs `apiServerCalls` per request to make this visible:

```
# direct
INFO served request models=5 apiServerCalls=1

# cached - same handler code
INFO served request models=5 apiServerCalls=0
```

The cached mode picks up creates and deletes instantly via the watch stream - no polling, no TTL, no cache invalidation logic.

The validation also runs two cached replicas on different ports, adds 3 models while both are running, and verifies both pick them up independently - no cross-replica coordination, no DB dirty flag, no controller push:

```
  replica-1: apiServerCalls=0
  replica-2: apiServerCalls=0
```

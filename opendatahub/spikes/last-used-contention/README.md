# last_used_at contention spike

Reproduces Postgres row-lock contention when many concurrent requests UPDATE the same row, and compares three strategies to fix it.

## The problem

When many concurrent requests arrive simultaneously with the same API key, they bypass Authorino's metadata cache (60s TTL) and each trigger a validation call to maas-api. Each validation fires an async goroutine to `UPDATE api_keys SET last_used_at = ...`. With 256+ goroutines racing to UPDATE the same row, Postgres row-level locking causes `context deadline exceeded` errors.

## Strategies tested

| Strategy | Query | How it helps |
|----------|-------|--------------|
| **bare** | `UPDATE ... SET last_used_at = now() WHERE id = $1` | Every request writes |
| **sql-guard** | Same + `AND last_used_at < now() - interval '60s'` | First write wins, rest are no-ops via WHERE |
| **skip-locked** | CTE with `FOR UPDATE SKIP LOCKED` | Non-blocking - losers return instantly |

## Running

Requires Docker and Go 1.22+.

```bash
./run.sh
```

Override the Postgres port if 5432 is taken:

```bash
DB_PORT=5433 ./run.sh
```

The script starts a throwaway Postgres container, seeds 10,000 keys, picks a random hot key per run, and cleans up on exit.

## What to expect

Connection pool is set to 25 max open / 5 idle (matching production). Each goroutine has a 2-second timeout. The table is seeded with 10,000 keys for realistic index/table size, and all concurrent requests target a single randomly chosen key (worst-case contention).

```
STRATEGY         CONC   ERRORS       WALL        p50        p95        p99
-------------- ------ -------- ---------- ---------- ---------- ----------
bare              256        0      431ms  225.706ms  408.773ms  422.851ms
bare             2048      763     2.021s  1.507927s  2.001346s  2.004753s
bare            10000     8757     2.114s  2.000047s  2.003258s  2.006666s

sql-guard         256        0       55ms   45.346ms    52.65ms   53.185ms
sql-guard        2048        0      138ms   88.762ms  126.917ms  130.871ms
sql-guard       10000        0      459ms  218.973ms  404.536ms   434.13ms

skip-locked       256        0       66ms   49.008ms    61.03ms   62.204ms
skip-locked      2048        0      153ms   98.024ms   145.52ms  148.928ms
skip-locked     10000        0      606ms  292.732ms  550.162ms  584.922ms
```

**bare** falls over at 2048 concurrency (763 errors, 87% failure at 10k). Both **sql-guard** and **skip-locked** handle 10,000 with zero errors.

## How it works

Under Postgres' default READ COMMITTED isolation, concurrent UPDATEs waiting on the same row re-check the WHERE clause after the first transaction commits. The sql-guard doesn't eliminate all lock waiting - waiters still briefly block behind the first writer - but it breaks the repeated write chain that causes the timeout cascade. After the first UPDATE commits, subsequent waiters re-evaluate the WHERE, find `last_used_at` is fresh, and return without writing.

SKIP LOCKED is the only truly non-blocking variant (losers return instantly without waiting). It may matter if the first update is held open by a long transaction. With short autocommit statements (our case), the simpler guarded UPDATE is the better production choice.

## Caveats

- The benchmark models one app replica with a 25-connection pool. Multiple replicas multiply DB-side concurrency, but the SQL guard handles that correctly since the deduplication lives in Postgres.
- The solution coalesces `last_used_at` precision to ~60 seconds. Fine for "recently used" metadata, not for exact audit timestamps.

## Takeaway

Both sql-guard and skip-locked fix the timeout pattern. sql-guard is simpler and sufficient for short standalone updates under default isolation. A one-line SQL WHERE clause replaces the need for application-level debounce state, and it works across replicas for free.

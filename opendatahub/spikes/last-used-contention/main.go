package main

import (
	"context"
	"database/sql"
	"fmt"
	"math/rand/v2"
	"os"
	"sort"
	"sync"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
)

const schema = `
CREATE TABLE IF NOT EXISTS api_keys (
	id     TEXT NOT NULL,
	tenant TEXT NOT NULL,
	last_used_at TIMESTAMPTZ,
	PRIMARY KEY (id, tenant)
);
CREATE INDEX IF NOT EXISTS idx_last_used ON api_keys(last_used_at) WHERE last_used_at IS NOT NULL;
`

const numKeys = 10_000

const bareQuery = `UPDATE api_keys SET last_used_at = now() WHERE id = $1 AND tenant = $2`

type strategy struct {
	name string
	// exec runs the UPDATE for one goroutine. Returns error from the DB call,
	// or nil if the call was skipped (e.g. debounce).
	exec func(ctx context.Context, db *sql.DB, keyID, tenant string) error
}

func sqlStrategy(name, query string) strategy {
	return strategy{
		name: name,
		exec: func(ctx context.Context, db *sql.DB, keyID, tenant string) error {
			_, err := db.ExecContext(ctx, query, keyID, tenant)
			return err
		},
	}
}

// debounce replicates the sync.Map + LoadOrStore + CompareAndSwap pattern
// from PR #1073. Each run gets a fresh debouncer.
type debouncer struct {
	m   sync.Map
	ttl time.Duration
}

func (d *debouncer) shouldUpdate(keyID string) bool {
	now := time.Now()
	actual, loaded := d.m.LoadOrStore(keyID, now)
	if !loaded {
		return true
	}
	lastTime, ok := actual.(time.Time)
	if ok && now.Sub(lastTime) >= d.ttl {
		return d.m.CompareAndSwap(keyID, actual, now)
	}
	return false
}

var concurrencyLevels = []int{256, 512, 1024, 2048, 10000}

func main() {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		dsn = "postgres://postgres:postgres@localhost:5432/perf_test?sslmode=disable"
	}

	db, err := sql.Open("pgx", dsn)
	if err != nil {
		fmt.Fprintf(os.Stderr, "open: %v\n", err)
		os.Exit(1)
	}
	defer db.Close()

	db.SetMaxOpenConns(25)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(5 * time.Minute)

	ctx := context.Background()
	if err := db.PingContext(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "ping: %v\n", err)
		os.Exit(1)
	}

	if _, err := db.ExecContext(ctx, schema); err != nil {
		fmt.Fprintf(os.Stderr, "schema: %v\n", err)
		os.Exit(1)
	}

	keys := seedKeys(ctx, db)

	strategies := []strategy{
		sqlStrategy("bare", bareQuery),
		sqlStrategy("sql-guard",
			`UPDATE api_keys SET last_used_at = now() WHERE id = $1 AND tenant = $2
			 AND (last_used_at IS NULL OR last_used_at < now() - interval '60 seconds')`),
		sqlStrategy("skip-locked",
			`WITH candidate AS (
				SELECT id, tenant FROM api_keys
				WHERE id = $1 AND tenant = $2
				  AND (last_used_at IS NULL OR last_used_at < now() - interval '60 seconds')
				FOR UPDATE SKIP LOCKED
			)
			UPDATE api_keys SET last_used_at = now()
			FROM candidate WHERE api_keys.id = candidate.id AND api_keys.tenant = candidate.tenant`),
	}

	// debounce strategy: fresh debouncer per concurrency level, same as
	// production where the sync.Map is process-scoped.
	debounceStrategy := strategy{
		name: "debounce",
	}

	fmt.Printf("%-14s %6s %8s %10s %10s %10s %10s\n",
		"STRATEGY", "CONC", "ERRORS", "WALL", "p50", "p95", "p99")
	fmt.Println("-------------- ------ -------- ---------- ---------- ---------- ----------")

	for _, s := range strategies {
		for _, conc := range concurrencyLevels {
			resetKeys(ctx, db)
			hotKey := keys[rand.IntN(len(keys))]
			errs, wall, lats := run(db, s, hotKey, conc)
			printRow(s.name, conc, errs, wall, lats)
		}
		fmt.Println()
	}

	// Debounce runs with a fresh debouncer per concurrency level
	for _, conc := range concurrencyLevels {
		resetKeys(ctx, db)
		hotKey := keys[rand.IntN(len(keys))]
		d := &debouncer{ttl: 60 * time.Second}
		debounceStrategy.exec = func(ctx context.Context, db *sql.DB, keyID, tenant string) error {
			if !d.shouldUpdate(keyID) {
				return nil
			}
			_, err := db.ExecContext(ctx, bareQuery, keyID, tenant)
			return err
		}
		errs, wall, lats := run(db, debounceStrategy, hotKey, conc)
		printRow(debounceStrategy.name, conc, errs, wall, lats)
	}
	fmt.Println()
}

func seedKeys(ctx context.Context, db *sql.DB) []string {
	const tenant = "perf-tenant"
	keys := make([]string, numKeys)
	for i := range numKeys {
		keys[i] = fmt.Sprintf("key-%04d", i)
	}

	for _, id := range keys {
		if _, err := db.ExecContext(ctx,
			`INSERT INTO api_keys (id, tenant, last_used_at) VALUES ($1, $2, now() - interval '10 minutes')
			 ON CONFLICT (id, tenant) DO NOTHING`, id, tenant); err != nil {
			fmt.Fprintf(os.Stderr, "seed: %v\n", err)
			os.Exit(1)
		}
	}

	fmt.Printf("Seeded %d keys\n\n", numKeys)
	return keys
}

func resetKeys(ctx context.Context, db *sql.DB) {
	if _, err := db.ExecContext(ctx,
		`UPDATE api_keys SET last_used_at = now() - interval '10 minutes' WHERE tenant = $1`,
		"perf-tenant"); err != nil {
		fmt.Fprintf(os.Stderr, "reset: %v\n", err)
		os.Exit(1)
	}
}

func printRow(name string, conc int, errCount int, wall time.Duration, latencies []time.Duration) {
	p50 := percentile(latencies, 0.50)
	p95 := percentile(latencies, 0.95)
	p99 := percentile(latencies, 0.99)
	fmt.Printf("%-14s %6d %8d %10s %10s %10s %10s\n",
		name, conc, errCount,
		wall.Truncate(time.Millisecond),
		p50.Truncate(time.Microsecond),
		p95.Truncate(time.Microsecond),
		p99.Truncate(time.Microsecond))
}

func run(db *sql.DB, s strategy, keyID string, concurrency int) (int, time.Duration, []time.Duration) {
	const tenant = "perf-tenant"
	var (
		mu        sync.Mutex
		wg        sync.WaitGroup
		errCount  int
		latencies = make([]time.Duration, 0, concurrency)
	)

	start := time.Now()

	for range concurrency {
		wg.Add(1)
		go func() {
			defer wg.Done()

			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()

			t0 := time.Now()
			err := s.exec(ctx, db, keyID, tenant)
			elapsed := time.Since(t0)

			mu.Lock()
			defer mu.Unlock()
			latencies = append(latencies, elapsed)
			if err != nil {
				errCount++
			}
		}()
	}

	wg.Wait()
	wall := time.Since(start)

	return errCount, wall, latencies
}

func percentile(data []time.Duration, p float64) time.Duration {
	if len(data) == 0 {
		return 0
	}
	sort.Slice(data, func(i, j int) bool { return data[i] < data[j] })
	idx := int(float64(len(data)-1) * p)
	return data[idx]
}

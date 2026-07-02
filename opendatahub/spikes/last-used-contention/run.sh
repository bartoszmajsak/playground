#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="perf-pg-last-used"
DB_NAME="perf_test"
DB_PORT="${DB_PORT:-5432}"
DSN="postgres://postgres:postgres@localhost:$DB_PORT/$DB_NAME?sslmode=disable"

cleanup() {
  echo "Stopping Postgres..."
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Remove stale container from a previous failed run
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

echo "Starting Postgres on port $DB_PORT..."
docker run --rm -d --name "$CONTAINER_NAME" \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB="$DB_NAME" \
  -p "$DB_PORT:5432" \
  postgres:16 >/dev/null

echo "Waiting for Postgres to accept connections..."
until docker exec "$CONTAINER_NAME" pg_isready -q 2>/dev/null; do
  sleep 0.5
done
# pg_isready reports ready before the host port forwarding is fully stable
# and before Postgres finishes its startup sequence. Retry the actual
# connection through the host port to be sure.
until docker exec "$CONTAINER_NAME" psql -U postgres -d "$DB_NAME" -c "SELECT 1" >/dev/null 2>&1; do
  sleep 0.5
done

echo ""
DATABASE_URL="$DSN" go run main.go

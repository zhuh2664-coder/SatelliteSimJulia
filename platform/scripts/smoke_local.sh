#!/bin/bash
# smoke_local.sh — 本地 Docker Compose 冒烟
# 启动 PostgreSQL + MinIO + API，验证 API 注册/认证/实验配置上传链路。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.local.yml"
KEEP_PLATFORM_SMOKE="${KEEP_PLATFORM_SMOKE:-0}"

for cmd in docker curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: required command not found: $cmd" >&2
        exit 1
    }
done

cleanup() {
    if [[ "$KEEP_PLATFORM_SMOKE" != "1" ]]; then
        docker compose -f "$COMPOSE_FILE" down -v >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

echo "starting local platform services..."
docker compose -f "$COMPOSE_FILE" up -d --build postgres minio api

echo "waiting for api health..."
for _ in $(seq 1 60); do
    if curl -fsS http://localhost:8080/api/health >/dev/null 2>&1; then
        break
    fi
    sleep 2
done
curl -fsS http://localhost:8080/api/health >/dev/null

echo "applying database migration..."
docker compose -f "$COMPOSE_FILE" exec -T postgres \
    psql -U postgres -d satnet -v ON_ERROR_STOP=1 \
    < "$PROJECT_ROOT/storage/migrations/001_initial.sql"

echo "creating MinIO buckets..."
docker compose -f "$COMPOSE_FILE" run --rm mc \
    'mc alias set local http://minio:9000 minioadmin minioadmin && mc mb --ignore-existing local/configs local/results'

echo "running API smoke..."
API=http://localhost:8080 SUBMIT_JOB=0 "$SCRIPT_DIR/smoke_api.sh"

echo "SMOKE LOCAL: ALL PASS"

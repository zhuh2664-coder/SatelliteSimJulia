#!/bin/bash
# smoke_local.sh — 本地 Docker Compose 全链路冒烟
# 启动 PostgreSQL + MinIO + API，跑 curl 链路验证

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.local.yml"

# 1. 启动依赖
docker compose -f "$COMPOSE_FILE" up -d postgres minio api

# 2. 等待就绪
echo "waiting for services..."
sleep 8

# 3. 初始化数据库
PGPASSWORD=postgres psql -h localhost -p 5432 -U postgres -d satnet \
    -f "$PROJECT_ROOT/storage/migrations/001_initial.sql"

# 4. 创建 MinIO buckets
docker run --rm --network host minio/mc:latest \
    alias set local http://localhost:9000 minioadmin minioadmin
docker run --rm --network host minio/mc:latest \
    mb local/configs local/results

# 5. curl 链路
API=http://localhost:8080
EMAIL=alice@example.com

echo "register..."
TOKEN=$(curl -sS -X POST "$API/api/register" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$EMAIL\"}" | jq -r .token)
echo "token: $TOKEN"

echo "me..."
curl -sS "$API/api/me" -H "Authorization: Bearer $TOKEN"

echo "create experiment..."
EXP_ID=$(curl -sS -X POST "$API/api/experiments" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"name":"walker48-test","config":{"constellation":"walker48"}}' | jq -r .id)
echo "experiment: $EXP_ID"

echo "submit job..."
JOB_ID=$(curl -sS -X POST "$API/api/experiments/$EXP_ID/jobs" \
    -H "Authorization: Bearer $TOKEN" | jq -r .id)
echo "job: $JOB_ID"

echo "job status..."
curl -sS "$API/api/jobs/$JOB_ID/status" -H "Authorization: Bearer $TOKEN"

echo "done."

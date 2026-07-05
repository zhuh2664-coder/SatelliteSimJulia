#!/bin/bash
# smoke_k3s.sh — K3s/Kubernetes 部署冒烟
# 使用 ClusterIP + kubectl port-forward，避免依赖云厂商 LoadBalancer。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$SCRIPT_DIR/../k8s"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="${K8S_NAMESPACE:-satnet}"
API_LOCAL_PORT="${API_LOCAL_PORT:-8080}"
PORT_FORWARD_PID=""

for cmd in kubectl curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: required command not found: $cmd" >&2
        exit 1
    }
done

cleanup() {
    if [[ -n "$PORT_FORWARD_PID" ]]; then
        kill "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

echo "applying k8s manifests..."
kubectl apply -k "$K8S_DIR"

echo "waiting for platform pods..."
kubectl -n "$NAMESPACE" wait --for=condition=ready pod -l app=postgres --timeout=180s
kubectl -n "$NAMESPACE" wait --for=condition=ready pod -l app=minio --timeout=180s
kubectl -n "$NAMESPACE" wait --for=condition=ready pod -l app=satnet-api --timeout=240s

echo "applying database migration..."
kubectl -n "$NAMESPACE" exec -i deploy/postgres -- \
    psql -U postgres -d satnet -v ON_ERROR_STOP=1 \
    < "$PROJECT_ROOT/storage/migrations/001_initial.sql"

echo "creating MinIO buckets..."
kubectl -n "$NAMESPACE" run satnet-mc-init --rm -i --restart=Never \
    --image=minio/mc:latest --command -- /bin/sh -lc \
    'mc alias set local http://minio:9000 minioadmin minioadmin && mc mb --ignore-existing local/configs local/results'

echo "port-forward satnet-api on local port $API_LOCAL_PORT..."
kubectl -n "$NAMESPACE" port-forward svc/satnet-api "$API_LOCAL_PORT:8080" >/tmp/satnet-api-port-forward.log 2>&1 &
PORT_FORWARD_PID=$!

for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:$API_LOCAL_PORT/api/health" >/dev/null 2>&1; then
        break
    fi
    sleep 2
done
curl -fsS "http://127.0.0.1:$API_LOCAL_PORT/api/health" >/dev/null

echo "running API + Job smoke..."
API="http://127.0.0.1:$API_LOCAL_PORT" SUBMIT_JOB=1 "$SCRIPT_DIR/smoke_api.sh"

echo "SMOKE K3S: ALL PASS"

#!/bin/bash
# smoke_k3s.sh — K3s 部署冒烟
# 假设本地已装好 k3s 并配置 kubectl

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$SCRIPT_DIR/../k8s"

echo "applying k8s manifests..."
kubectl apply -k "$K8S_DIR"

echo "waiting pods running..."
kubectl -n satnet wait --for=condition=ready pod -l app --timeout=120s

API=http://$(kubectl -n satnet get svc satnet-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'):8080
echo "api at: $API"

# 跑 smoke_local.sh 同样的 curl 链路
K3S_API=$API bash "$SCRIPT_DIR/smoke_local.sh"

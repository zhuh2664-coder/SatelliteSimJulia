#!/bin/bash
# smoke_api.sh — API-only curl smoke, reusable by local Docker and K8s smoke.

set -euo pipefail

API="${API:-http://localhost:8080}"
SUBMIT_JOB="${SUBMIT_JOB:-0}"
EMAIL="alice+$(date +%s)@example.com"

for cmd in curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: required command not found: $cmd" >&2
        exit 1
    }
done

echo "api: $API"

echo "health..."
curl -fsS "$API/api/health" >/dev/null

echo "register..."
TOKEN=$(curl -fsS -X POST "$API/api/register" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$EMAIL\"}" | jq -r .token)
if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
    echo "ERROR: register did not return token" >&2
    exit 1
fi

echo "me..."
ME=$(curl -fsS "$API/api/me" -H "Authorization: Bearer $TOKEN")
echo "$ME" | jq -e --arg email "$EMAIL" '.email == $email' >/dev/null

echo "create experiment..."
EXP_ID=$(curl -fsS -X POST "$API/api/experiments" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"name":"walker48-test","config":{"name":"walker48-test","constellation":"walker48","steps":5}}' | jq -r .id)
if [[ -z "$EXP_ID" || "$EXP_ID" == "null" ]]; then
    echo "ERROR: create experiment did not return id" >&2
    exit 1
fi
echo "experiment: $EXP_ID"

if [[ "$SUBMIT_JOB" == "1" ]]; then
    echo "submit job..."
    JOB_ID=$(curl -fsS -X POST "$API/api/experiments/$EXP_ID/jobs" \
        -H "Authorization: Bearer $TOKEN" | jq -r .id)
    if [[ -z "$JOB_ID" || "$JOB_ID" == "null" ]]; then
        echo "ERROR: submit job did not return id" >&2
        exit 1
    fi
    echo "job: $JOB_ID"

    echo "poll job..."
    for _ in $(seq 1 60); do
        STATUS=$(curl -fsS "$API/api/jobs/$JOB_ID/status" \
            -H "Authorization: Bearer $TOKEN" | jq -r .status)
        echo "status: $STATUS"
        case "$STATUS" in
            succeeded)
                curl -fsS "$API/api/jobs/$JOB_ID/result.json" \
                    -H "Authorization: Bearer $TOKEN" | jq -e '.fitness != null' >/dev/null
                curl -fsS "$API/api/jobs/$JOB_ID/artifacts" \
                    -H "Authorization: Bearer $TOKEN" | jq -e '
                        (.files | length >= 3) and
                        any(.files[]; .path == "result.json") and
                        any(.files[]; .path == "config.snapshot.json") and
                        any(.files[]; .path == "run_metadata.json")
                    ' >/dev/null
                curl -fsS "$API/api/jobs/$JOB_ID/download?file=run_metadata.json" \
                    -H "Authorization: Bearer $TOKEN" | jq -e '.julia.version != null and .duration_s != null' >/dev/null
                curl -fsS "$API/api/jobs/$JOB_ID/download?file=config.snapshot.json" \
                    -H "Authorization: Bearer $TOKEN" | jq -e '.name == "walker48-test"' >/dev/null
                curl -fsS "$API/api/jobs/$JOB_ID/logs" \
                    -H "Authorization: Bearer $TOKEN" | grep -q '\[runner\]'
                echo "SMOKE API: JOB SUCCEEDED"
                exit 0
                ;;
            failed)
                echo "ERROR: job failed" >&2
                exit 1
                ;;
        esac
        sleep 5
    done
    echo "ERROR: job did not complete in time" >&2
    exit 1
fi

echo "SMOKE API: ALL PASS"

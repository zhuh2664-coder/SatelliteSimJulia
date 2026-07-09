#!/usr/bin/env bash
# 每日运行 SatelliteSimJulia 论文知识库 Agent。
# 不在脚本里硬编码 key；优先读取环境变量，其次从 PAPER_AGENT_CPA_FILE 指向的本地配置文件解析。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENT_DIR="$PROJECT_DIR/docs/literature/_paper_agent"
LOG_DIR="$AGENT_DIR/logs"
mkdir -p "$LOG_DIR"

CPA_FILE="${PAPER_AGENT_CPA_FILE:-/Users/zhuhai/Research/github上很牛逼的项目/langgraph/CPA配置信息.md}"

read_cpa_value() {
  local key="$1"
  local default_value="${2:-}"
  python3 - "$CPA_FILE" "$key" "$default_value" <<'PY'
import os
import re
import sys

path, key, default = sys.argv[1:4]
text = ""
if path and os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
pattern = re.compile(r"^\s*" + re.escape(key) + r"\s*=\s*([^\s`\"']+)", re.MULTILINE)
match = pattern.search(text)
print(match.group(1) if match else default)
PY
}

if [[ -z "${OPENAI_BASE_URL:-}" ]]; then
  export OPENAI_BASE_URL="$(read_cpa_value OPENAI_BASE_URL http://127.0.0.1:8317/v1)"
fi

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  parsed_key="$(read_cpa_value OPENAI_API_KEY '')"
  if [[ -n "$parsed_key" ]]; then
    export OPENAI_API_KEY="$parsed_key"
  fi
fi

if [[ -z "${OPENAI_MODEL_NAME:-}" ]]; then
  export OPENAI_MODEL_NAME="$(read_cpa_value OPENAI_MODEL_NAME gpt-5.5)"
fi

export HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:7890}"
export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:7890}"
export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost}"

DAYS="${PAPER_AGENT_DAYS:-1}"
MAX_PER_QUERY="${PAPER_AGENT_MAX_PER_QUERY:-5}"
MAX_CANDIDATES="${PAPER_AGENT_MAX_CANDIDATES:-20}"
MAX_LLM_PAPERS="${PAPER_AGENT_MAX_LLM_PAPERS:-5}"
MIN_FILTER_SCORE="${PAPER_AGENT_MIN_FILTER_SCORE:-35}"

log_file="$LOG_DIR/daily-$(date +%Y%m%d).log"
{
  echo "[$(date -Is)] start paper agent daily"
  echo "project=$PROJECT_DIR"
  echo "model=${OPENAI_MODEL_NAME:-unset} base_url_set=$([[ -n "${OPENAI_BASE_URL:-}" ]] && echo yes || echo no) key_set=$([[ -n "${OPENAI_API_KEY:-}" ]] && echo yes || echo no)"
  cd "$PROJECT_DIR"
  python3 scripts/run_paper_agent.py daily \
    --days "$DAYS" \
    --max-per-query "$MAX_PER_QUERY" \
    --max-candidates "$MAX_CANDIDATES" \
    --max-llm-papers "$MAX_LLM_PAPERS" \
    --min-filter-score "$MIN_FILTER_SCORE"
  python3 scripts/run_paper_agent.py weekly --dry-run
  echo "[$(date -Is)] done paper agent daily"
} >> "$log_file" 2>&1

#!/bin/bash
# Satellite Agent 容器入口
#
# 用法: entrypoint.sh --sat-id N [--control-plane HOST:PORT]
#   --sat-id        : 卫星 ID（必填）
#   --control-plane : 控制平面地址（可选）

set -euo pipefail

SAT_ID=""
CONTROL_PLANE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --sat-id) SAT_ID="$2"; shift 2 ;;
        --control-plane) CONTROL_PLANE="$2"; shift 2 ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done

if [[ -z "$SAT_ID" ]]; then
    echo "错误: --sat-id 必填" >&2
    exit 1
fi

echo "=== 卫星 $SAT_ID Agent 启动 ==="
echo "控制平面: ${CONTROL_PLANE:-无}"

export SAT_ID
export CONTROL_PLANE
export SAT_HOSTNAME="sat-$(printf '%03d' "$SAT_ID")"
export AGENT_DT="${AGENT_DT:-1.0}"
export AGENT_TIMEOUT_S="${AGENT_TIMEOUT_S:-Inf}"

echo "$SAT_HOSTNAME" > /etc/hostname 2>/dev/null || true
touch /tmp/satellite-agent-ready

cd /opt/satellite/agent_runtime

echo "启动 Julia Agent Runtime..."
exec julia --project=/opt/satellite/agent_runtime -e '
using SatelliteSimAgentRuntime

sat_id = parse(Int, get(ENV, "SAT_ID", "0"))
dt = parse(Float64, get(ENV, "AGENT_DT", "1.0"))
timeout_s = parse(Float64, get(ENV, "AGENT_TIMEOUT_S", "Inf"))

config = SatelliteSimAgentRuntime.AgentConfig(sat_id = sat_id)
state = SatelliteSimAgentRuntime.SatelliteAgentState(id = sat_id)
agent = SatelliteSimAgentRuntime.SimpleAgent(config = config, state = state)
runtime = SatelliteSimAgentRuntime.AgentRuntime(agent = agent, dt = dt)

println("[agent] SAT-$(sat_id) runtime started dt=$(dt) timeout=$(timeout_s)")
runtime(; timeout_s = timeout_s)
'

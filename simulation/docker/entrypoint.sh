#!/bin/bash
# Satellite Agent 容器入口
#
# 用法: entrypoint.sh --sat-id N [--control-plane HOST:PORT]
#   --sat-id        : 卫星 ID（必填）
#   --control-plane : 控制平面地址（可选）

set -e

# 解析参数
SAT_ID=""
CONTROL_PLANE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --sat-id) SAT_ID="$2"; shift 2 ;;
        --control-plane) CONTROL_PLANE="$2"; shift 2 ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done

if [ -z "$SAT_ID" ]; then
    echo "错误: --sat-id 必填"
    exit 1
fi

echo "=== 卫星 $SAT_ID Agent 启动 ==="
echo "控制平面: ${CONTROL_PLANE:-无}"

# 设置环境变量
export SAT_ID=$SAT_ID
export SAT_HOSTNAME="sat-$(printf '%03d' $SAT_ID)"
hostname $SAT_HOSTNAME

# 启动 Agent Runtime（后台）
cd /opt/satellite/agent_runtime
echo "启动 Agent Runtime..."

# Julia 版本（未来用）
# julia -e "using SatelliteSimAgentRuntime; AgentRuntime(SimpleAgent(AgentConfig(sat_id=$SAT_ID))).loop(timeout_s=Inf)"

# 目前：模拟 Agent 心跳
while true; do
    echo "[$(date -Iseconds)] SAT-$SAT_ID: 心跳 - 电量正常"
    sleep 10
done

# ===== 简单仿真示例 =====
# 演示：启动 N 个卫星 Agent，用时间步进模式运行
#
# 用法：
#   julia --project=agent_runtime simple_simulation.jl

using Test

# 手动加载 Agent Runtime（后续可做成正式包）
include("../agent_runtime/src/AgentRuntime.jl")
using .SatelliteSimAgentRuntime

# ------------------------------------------------------------
# 配置
# ------------------------------------------------------------
N_SATELLITES = 10          # 卫星数
SIM_STEPS = 1000           # 仿真步数
DT = 0.1                   # 每步时间（秒）

println("="^60)
println("自治卫星仿真 — $(N_SATELLITES) 颗卫星 × $(SIM_STEPS) 步")
println("="^60)

# ------------------------------------------------------------
# 创建卫星 Agent 集合
# ------------------------------------------------------------
agents = [SimpleAgent(
    config = AgentConfig(sat_id = i, llm_enabled = false),
    state = SatelliteAgentState(id = i, x = rand() * 1000, y = rand() * 1000, z = rand() * 1000)
) for i in 1:N_SATELLITES]

# ------------------------------------------------------------
# 主仿真循环
# ------------------------------------------------------------
metrics = Dict{String, Float64}(
    "total_messages" => 0.0,
    "total_power" => 0.0,
    "min_power" => 1.0,
    "total_buffer" => 0.0,
)

for step in 1:SIM_STEPS
    # 1. 轨道更新（简化：模拟位置变化）
    for (i, agent) in enumerate(agents)
        angle = step * DT * 0.001 + i * 2π / N_SATELLITES
        agent.state.x = 7000 * cos(angle)
        agent.state.z = 7000 * sin(angle)
    end

    # 2. 计算邻居（简化：距离 < 2000 km 即为邻居）
    for i in 1:N_SATELLITES, j in (i+1):N_SATELLITES
        a1 = agents[i]
        a2 = agents[j]
        dx = a1.state.x - a2.state.x
        dy = a1.state.y - a2.state.y
        dz = a1.state.z - a2.state.z
        dist = sqrt(dx^2 + dy^2 + dz^2)

        if dist < 2000
            # 发送一个探测事件
            push_event!(AgentRuntime(a1), LinkChange(
                step * DT, j, :up,
                dist / 299792.458 * 1000,  # 光速延迟（ms）
                100.0                        # 100 Mbps
            ))
        end
    end

    # 3. 每个 Agent 走一步
    for agent in agents
        step!(agent, DT)
        if step % 100 == 0
            think!(agent)
            remember!(agent)
        end
    end

    # 4. 采集指标
    total_power = sum(a.state.power_level for a in agents)
    min_power = minimum(a.state.power_level for a in agents)
    total_buffer = sum(a.state.buffer_usage_mb for a in agents)

    if step % 200 == 0
        println("步 $step: 平均电量=$(total_power/N_SATELLITES) 最低电量=$min_power 缓存总量=$(round(total_buffer, digits=2)) MB")
    end

    metrics["total_power"] = total_power
    metrics["min_power"] = min(min_power, metrics["min_power"])
    metrics["total_buffer"] = total_buffer
end

println("-"^60)
println("仿真完成 $(SIM_STEPS) 步")
println("最终总电量: $(round(metrics["total_power"], digits=2))")
println("最终最低电量: $(round(metrics["min_power"], digits=4))")
println("最终缓存总量: $(round(metrics["total_buffer"], digits=2)) MB")
println("="^60)

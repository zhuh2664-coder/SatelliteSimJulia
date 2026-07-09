# ===== 事件系统 & Agent 抽象 =====

"""
    LinkChange

链路状态变化事件。
"""
struct LinkChange <: SatelliteEvent
    time::Float64
    neighbor_id::Int
    status::Symbol    # :up, :down, :degraded
    delay_ms::Float64
    bandwidth_mbps::Float64
end

"""
    BundleArrival

收到 DTN Bundle 事件。
"""
struct BundleArrival <: SatelliteEvent
    time::Float64
    from_id::Int
    bundle::Vector{UInt8}
    priority::Int   # 0-3
end

"""
    OrbitUpdate

轨道位置更新事件。
"""
struct OrbitUpdate <: SatelliteEvent
    time::Float64
    pos_x::Float64; pos_y::Float64; pos_z::Float64
    vel_x::Float64; vel_y::Float64; vel_z::Float64
end

"""
    MissionArrival

新任务到达事件。
"""
struct MissionArrival <: SatelliteEvent
    time::Float64
    mission_id::String
    mission_type::Symbol  # :forward, :compute, :sense, :report
    flops::Float64
    data_mb::Float64
    deadline_s::Float64
end

"""
    AbstractAgent

卫星 Agent 的抽象接口。

所有 Agent 必须实现：
- process_event!(agent, event)
- should_think(agent) → Bool
- think!(agent)
- step!(agent, dt)
- remember!(agent)
"""
abstract type AbstractAgent end

"""
    AgentConfig

Agent 静态配置。
"""
@kwdef struct AgentConfig
    sat_id::Int
    cpu_flops::Float64 = 1e9      # 1 GFLOPS
    mem_mb::Float64 = 512.0
    storage_mb::Float64 = 1024.0
    power_budget_w::Float64 = 20.0
    llm_enabled::Bool = true
    llm_api_key::String = ""
    llm_model::String = "claude-sonnet-4-20250514"
end

"""
    SatelliteAgentState

卫星 Agent 当前状态（运行时可变）。
"""
@kwdef mutable struct SatelliteAgentState
    id::Int = 0
    x::Float64 = 0.0; y::Float64 = 0.0; z::Float64 = 0.0
    vx::Float64 = 0.0; vy::Float64 = 0.0; vz::Float64 = 0.0
    neighbors::Vector{Int} = Int[]
    link_delays::Dict{Int, Float64} = Dict{Int, Float64}()
    link_bandwidths::Dict{Int, Float64} = Dict{Int, Float64}()
    buffer_usage_mb::Float64 = 0.0
    power_level::Float64 = 1.0
    health::Symbol = :healthy   # :healthy, :degraded, :critical
    pending_tasks::Vector{Mission} = Mission[]
end

"""
    SimpleAgent

最简实现的卫星 Agent，用于原型验证。
"""
@kwdef mutable struct SimpleAgent <: AbstractAgent
    config::AgentConfig
    state::SatelliteAgentState
    memory::MemoryStore = MemoryStore()
    think_counter::Int = 0
end

# ===== 默认方法实现 =====

function process_event!(agent::SimpleAgent, event::SatelliteEvent)
    push!(agent.memory.recent_events, event)
end

function should_think(agent::SimpleAgent)::Bool
    # 每 100 步思考一次，或者有高优先级事件
    return agent.think_counter % 100 == 0
end

function think!(agent::SimpleAgent)
    # LLM 调用占位（后续集成真实模型）
    # 目前：基于规则的简单决策
    agent.think_counter += 1
end

function step!(agent::SimpleAgent, dt::Float64)
    # 耗电模拟
    agent.state.power_level -= 0.0001 * dt
    agent.state.power_level = max(0.0, agent.state.power_level)

    # 缓存管理
    agent.state.buffer_usage_mb *= 0.99  # 自然衰减

    # 健康检查
    if agent.state.power_level < 0.1
        agent.state.health = :critical
    elseif agent.state.power_level < 0.3
        agent.state.health = :degraded
    end
end

function remember!(agent::SimpleAgent)
    # 定期记录链路统计到长期记忆
    if agent.think_counter % 1000 == 0
        n = length(agent.state.neighbors)
        agent.memory.link_delay_history[agent.think_counter] =
            n > 0 ? mean(values(agent.state.link_delays)) : 0.0
        agent.memory.buffer_history[agent.think_counter] = agent.state.buffer_usage_mb
    end
end

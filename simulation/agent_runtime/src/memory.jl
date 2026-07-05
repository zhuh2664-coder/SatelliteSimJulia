# ===== 记忆系统 =====

"""
    Pattern

学习到的网络行为模式。
"""
Base.@kwdef struct Pattern
    description::String
    confidence::Float64    # 0.0 - 1.0
    first_seen::Int
    last_seen::Int
    occurrences::Int
end

"""
    MemoryStore

卫星 Agent 的记忆系统。

包含三层：
1. 工作记忆 — 最近事件缓存
2. 情景记忆 — 链路状态历史
3. 语义记忆 — 学习到的模式

记忆的持久化目前用内存 Dict，后续可接入 SQLite/Parquet。
"""
@kwdef mutable struct MemoryStore
    # === 工作记忆（短期）===
    recent_events::CircularBuffer{SatelliteEvent} = CircularBuffer{SatelliteEvent}(1000)
    last_think_time::Float64 = 0.0
    think_count::Int = 0

    # === 情景记忆（中期）===
    link_delay_history::Dict{Int, Float64} = Dict{Int, Float64}()
    buffer_history::Dict{Int, Float64} = Dict{Int, Float64}()
    neighbor_history::Dict{Int, Vector{Int}} = Dict{Int, Vector{Int}}()
    message_sent::Int = 0
    message_received::Int = 0

    # === 语义记忆（长期）===
    patterns::Vector{Pattern} = Pattern[]
    knowledge_points::Dict{String, Float64} = Dict{String, Float64}()

    # === 持久化（预留）===
    persistence_path::String = ""
    auto_save_interval::Int = 3600  # 每 3600 tick 自动保存
end

"""
    recall_recent_events(memory, n)

返回最近的 n 个事件。
"""
function recall_recent_events(memory::MemoryStore, n::Int)::Vector{SatelliteEvent}
    events = collect(memory.recent_events)
    return events[max(1, end-n+1):end]
end

"""
    recall_link_pattern(memory, link_id)

查询某条链路的已知行为模式。
"""
function recall_link_pattern(memory::MemoryStore, link_id::Int)::Vector{Pattern}
    return [p for p in memory.patterns if occursin(string(link_id), p.description)]
end

"""
    learn_pattern!(memory, description, confidence)

记录一个观察到的模式。
"""
function learn_pattern!(memory::MemoryStore, description::String, confidence::Float64)
    existing = findfirst(p -> p.description == description, memory.patterns)
    if existing !== nothing
        p = memory.patterns[existing]
        memory.patterns[existing] = Pattern(
            description, p.confidence,
            p.first_seen, memory.think_count,
            p.occurrences + 1
        )
    else
        push!(memory.patterns, Pattern(description, confidence, memory.think_count, memory.think_count, 1))
    end
end

"""
    summarize_state(memory, agent_id)

生成 Agent 当前状态的自然语言摘要（供 LLM 使用）。
"""
function summarize_state(memory::MemoryStore, agent_id::Int)::String
    recent = recall_recent_events(memory, 10)
    n_events = length(recent)
    n_links = length(keys(memory.link_delay_history))

    return """
    Agent $agent_id 当前状态摘要：
    - 最近存储事件数: $n_events
    - 已记录链路数: $n_links
    - 消息收发: 发 $(memory.message_sent) / 收 $(memory.message_received)
    - 已知模式数: $(length(memory.patterns))
    """
end

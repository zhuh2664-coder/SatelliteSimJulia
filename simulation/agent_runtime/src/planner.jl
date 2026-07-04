# ===== 规划系统 =====

"""
    Mission

一个具体的执行任务。
"""
@kwdef struct Mission
    id::String
    priority::Int           # 0-3, 0=最高
    mission_type::Symbol    # :forward, :compute, :sense, :report
    flops::Float64          # 所需算力
    data_mb::Float64        # 所需带宽/存储
    deadline_s::Float64     # 截止时间
    source_id::Int          # 发起者
    target_id::Int          # 目标（0=广播）
    payload::Vector{UInt8} = UInt8[]
    created_at::Float64 = time()
end

"""
    Task

更小粒度的执行单元（Mission 的子步骤）。
"""
@kwdef struct Task
    id::String
    mission_id::String
    action::Symbol          # :send, :compute, :store, :delete, :sense
    params::Dict{String, Any} = Dict{String, Any}()
    status::Symbol = :pending  # :pending, :running, :completed, :failed
end

"""
    Goal

卫星的长期目标（由人类设定或 Agent 自我生成）。
"""
@kwdef struct Goal
    description::String
    priority::Int = 1
    deadline::Float64 = Inf
    status::Symbol = :active   # :active, :paused, :completed, :failed
    subgoals::Vector{Goal} = Goal[]
end

"""
    Planner

将长期目标分解为可执行的任务序列。
"""
@kwdef mutable struct Planner
    goals::Vector{Goal} = Goal[]
    missions::Vector{Mission} = Mission[]
    completed_missions::Vector{Mission} = Mission[]
end

"""
    add_goal!(planner, goal)

添加一个长期目标。
"""
function add_goal!(planner::Planner, goal::Goal)
    push!(planner.goals, goal)
end

"""
    add_mission!(planner, mission)

添加一个任务到队列（按优先级排序）。
"""
function add_mission!(planner::Planner, mission::Mission)
    push!(planner.missions, mission)
    sort!(planner.missions, by = m -> (m.priority, m.deadline_s))
end

"""
    next_mission(planner)

获取下一个最高优先级的任务。
"""
function next_mission(planner::Planner)::Union{Mission, Nothing}
    if isempty(planner.missions)
        return nothing
    end
    return planner.missions[1]
end

"""
    complete_mission!(planner, mission_id)

标记任务完成。
"""
function complete_mission!(planner::Planner, mission_id::String)
    idx = findfirst(m -> m.id == mission_id, planner.missions)
    if idx !== nothing
        completed = splice!(planner.missions, idx)
        push!(planner.completed_missions, completed)
    end
end

"""
    decompose_goal(goal, sat_id, base_time)

将目标分解为多个 Mission（启发式规则）。

举例：
- 目标"保持网络连通率 > 99%"
  → Mission: 每 60s 检测一次邻居
  → Mission: 延迟 > 50ms 重路由
  → Mission: 记录链路统计
"""
function decompose_goal(goal::Goal, sat_id::Int, base_time::Float64)::Vector{Mission}
    missions = Mission[]
    desc = goal.description

    if occursin("连通率", desc)
        push!(missions, Mission(
            "detect_links_$(sat_id)_$(Int(base_time))",
            1, :sense, 1e6, 0.001, base_time + 60.0,
            sat_id, 0
        ))
        push!(missions, Mission(
            "reroute_check_$(sat_id)_$(Int(base_time))",
            0, :compute, 5e8, 0.0, base_time + 10.0,
            sat_id, 0
        ))
    elseif occursin("缓存", desc) || occursin("buffer", lowercase(desc))
        push!(missions, Mission(
            "buffer_cleanup_$(sat_id)_$(Int(base_time))",
            2, :compute, 1e7, 0.1, base_time + 120.0,
            sat_id, 0
        ))
    else
        # 默认：探测任务
        push!(missions, Mission(
            "explore_$(sat_id)_$(Int(base_time))",
            3, :sense, 1e6, 0.001, base_time + 300.0,
            sat_id, 0
        ))
    end

    return missions
end

# 预定义的目标模板

"""
    connectivity_goal

保持网络连通率 > 99% 的长期目标。
"""
function connectivity_goal()::Goal
    return Goal(
        "保持网络连通率 > 99%",
        0,
        Inf,
        :active,
        [
            Goal("监控 ISL 链路延迟", 1, Inf, :active, Goal[]),
            Goal("延迟 > 50ms 时触发重路由", 1, Inf, :active, Goal[]),
            Goal("每 15min 记录链路统计到 memory", 2, Inf, :active, Goal[]),
        ]
    )
end

"""
    power_efficient_goal

省电模式目标。
"""
function power_efficient_goal()::Goal
    return Goal(
        "功率管理：电量 > 50%",
        1,
        Inf,
        :active,
        [
            Goal("非活跃链路关闭发射机", 1, Inf, :active, Goal[]),
            Goal("降低低于优先级 2 的 bundle 转发频率", 2, Inf, :active, Goal[]),
        ]
    )
end

# ===== Goal catalog =====

export GoalInfo, GOAL_CATALOG, goal_info, list_goals, describe_goal

struct GoalInfo
    id::Symbol
    name::String
    description::String
    recommended_study::DataType
    recommended_metrics::Vector{Symbol}
    recommended_traffic::Vector{Symbol}
    recommended_routing::Vector{Symbol}
    recommended_topology::Vector{Symbol}  # 拓扑意图推荐（防泄漏：意图而非策略名）
    recommended_constellation::Vector  # 星座意图推荐（Symbol 或三维度元组，如 (:global,:low_latency,:medium)）
end

const GOAL_CATALOG = Dict{Symbol,GoalInfo}(
    :routing_comparison => GoalInfo(
        :routing_comparison,
        "路由对比",
        "比较不同路由算法在同一星座和流量模型下的表现。",
        RoutingStudy,
        [:latency, :connectivity, :utilization],
        [:uniform, :hotspot],
        [:shortest_path, :load_balanced, :multipath],
        [:balanced],  # 拓扑固定（比路由，不比拓扑）
        [(:global, :low_latency, :small)],  # 小规模够跑路由
    ),
    :constellation_comparison => GoalInfo(
        :constellation_comparison,
        "星座对比",
        "比较不同星座构型在相同路由和流量假设下的覆盖与性能。",
        ConstellationStudy,
        [:coverage, :latency, :connectivity],
        [:uniform],
        [:shortest_path],
        [:balanced],
        [(:global, :low_latency, :medium), (:polar, :high_latency, :large)],  # 对比用
    ),
    :capacity_analysis => GoalInfo(
        :capacity_analysis,
        "容量分析",
        "扫描用户规模或需求强度，分析容量和利用率变化。",
        CapacityStudy,
        [:utilization, :latency],
        [:hotspot, :video],
        [:shortest_path, :load_balanced],
        [:low_cost, :balanced],  # 容量场景常需省 ISL
        [(:global, :low_latency, :large)],  # 大规模才有容量意义
    ),
    :coverage_analysis => GoalInfo(
        :coverage_analysis,
        "覆盖分析",
        "分析给定星座在指定纬度范围或地面点集合上的覆盖能力。",
        CoverageStudy,
        [:coverage, :latency],
        [:uniform, :iot],
        [:shortest_path],
        [:balanced],
        [(:polar, :mid_latency, :medium), (:global, :low_latency, :medium)],  # 覆盖对比
    ),
    :vulnerability_analysis => GoalInfo(
        :vulnerability_analysis,
        "脆弱性分析",
        "评估节点或链路失效对网络连通性与路径长度的影响。",
        VulnerabilityStudy,
        [:connectivity, :diameter],
        [:uniform],
        [:shortest_path],
        [:high_robust],  # 脆弱性分析关注鲁棒拓扑
        [(:global, :low_latency, :medium)],
    ),
    :cache_analysis => GoalInfo(
        :cache_analysis,
        "缓存分析",
        "扫描星上缓存容量配置，分析延迟和命中收益。",
        CacheStudy,
        [:latency, :utilization],
        [:video, :hotspot],
        [:shortest_path],
        [:low_latency],  # 缓存降时延
        [(:global, :low_latency, :large)],
    ),
)

function goal_info(goal::Symbol)
    haskey(GOAL_CATALOG, goal) || error("unknown goal: $goal")
    return GOAL_CATALOG[goal]
end

list_goals() = sort(collect(keys(GOAL_CATALOG)), by=id -> GOAL_CATALOG[id].name)

function describe_goal(goal::Symbol)
    g = goal_info(goal)
    return "$(g.name) — $(g.description)"
end

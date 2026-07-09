# ===== 路由/接入/切换能力目录 =====
#
# ROUTING_CATALOG 是面向工程发现的元数据目录，不是算法实现注册表，
# 也不是唯一真相源。真实入口以 Net/Traffic/Lab 的公开 API、测试与算法目录为准。
# Core 目录层不得反向依赖 Net/Traffic/Lab；这里只记录名称、入口提示和适用边界。

export list_routing, describe_routing, filter_routing_by_goal

"""
    RoutingInfo

路由算法元信息。

# 字段
- `id::Symbol`: 唯一标识
- `name::String`: 显示名称
- `description::String`: 算法说明
- `category::Symbol`: 类别（:shortest_path, :qos, :load_balance, ...）
- `suitable_for::Vector{Symbol}`: 适用目标
- `not_suitable_for::Vector{Symbol}`: 不适用场景
"""
struct RoutingInfo
    id::Symbol
    name::String
    description::String
    category::Symbol
    suitable_for::Vector{Symbol}
    not_suitable_for::Vector{Symbol}
end

const ROUTING_CATALOG = Dict{Symbol,RoutingInfo}(
    :dijkstra => RoutingInfo(
        :dijkstra,
        "Dijkstra",
        "最短路径路由；入口 DijkstraRouting 与 route(::DijkstraRouting, ::RoutingInput)，按链路权重/传播时延求单路径最短路。",
        :shortest_path,
        [:latency, :small_network, :single_path],
        [:load_balance, :multipath],
    ),
    :ecmp => RoutingInfo(
        :ecmp,
        "ECMP",
        "等价多路径路由；入口 ECMPRouting、ecmp_paths 与 route(::ECMPRouting, ::RoutingInput)，用于在等价路径间分摊流量。",
        :load_balance,
        [:load_balance, :large_network, :multipath],
        [:strict_single_path],
    ),
    :min_load => RoutingInfo(
        :min_load,
        "MinLoad",
        "最小负载路由；入口 MinLoadRouting、min_load_path 与 Traffic evaluate_traffic(..., MinLoadRouting())。普通 route(::MinLoadRouting, ::RoutingInput) 无 current_loads 时会退化为最短路。",
        :load_balance,
        [:load_balance, :traffic_engineering, :congestion_avoidance],
        [:latency_only, :no_load_state],
    ),
    :pinn => RoutingInfo(
        :pinn,
        "PINN routing",
        "学习型时延预测路由；入口 PINNRoutingAlgorithm 与 route。当前 route 产出 latency/total_weight 预测，path 为空，不适合作为 AON link-load path 直接使用。",
        :learned,
        [:latency_prediction, :surrogate_model],
        [:link_load_assignment, :path_enumeration],
    ),
    :cgr => RoutingInfo(
        :cgr,
        "CGR",
        "Contact Graph Routing；入口 CGRRouting、CGRContactPlan 与 route(::CGRRouting, cp, src, dst, t)，面向 contact plan/time-expanded 场景，不是普通静态 RoutingInput。",
        :contact_plan,
        [:delay_tolerant, :time_expanded, :scheduled_contacts],
        [:static_snapshot, :plain_routing_input],
    ),
    :end_to_end_physical => RoutingInfo(
        :end_to_end_physical,
        "End-to-end physical routing",
        "端到端物理路由；入口 RouteRequest、route_path_at 与 route_series，组合 GSL 接入、ISL shortest-delay 路径和目标 GSL。默认 ISL 为 shortest-delay，不等价于 MinLoad/ECMP。",
        :end_to_end,
        [:ground_to_ground, :latency, :gsl, :isl],
        [:load_balance, :multipath],
    ),
    :gsl_access => RoutingInfo(
        :gsl_access,
        "GSL access",
        "地卫接入选择；入口 AccessDecisionTable 与 build_access_decision_table，可结合 handover policy 从可用 GSLPhysicalLinkSample 中选接入卫星。",
        :access,
        [:gsl, :access, :ground_to_satellite],
        [:isl_routing, :end_to_end_path_only],
    ),
    :handover => RoutingInfo(
        :handover,
        "Handover policy",
        "接入切换策略；入口 AbstractHandoverPolicy、ElevationThreshold、LongestVisible、NearestDistance、select_satellite 与 count_handovers，用于控制 GSL 接入切换行为。",
        :handover,
        [:handover, :gsl, :access_stability],
        [:isl_routing, :traffic_splitting],
    ),
)

list_routing() = sort(collect(keys(ROUTING_CATALOG)), by = id -> ROUTING_CATALOG[id].name)

function describe_routing(id::Symbol)
    haskey(ROUTING_CATALOG, id) || return "unknown routing: $id"
    r = ROUTING_CATALOG[id]
    suitable = join(string.(r.suitable_for), ", ")
    not_suitable = join(string.(r.not_suitable_for), ", ")
    return "$(r.name) — $(r.description) | 适用: $suitable | 不适用: $not_suitable"
end

function filter_routing_by_goal(goal::Symbol)
    results = Pair{Symbol,String}[]
    for (id, r) in ROUTING_CATALOG
        if goal in r.suitable_for
            push!(results, id => r.name)
        end
    end
    return results
end

# ===== 路由算法目录 =====

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
        :dijkstra, "Dijkstra", "最短路径路由（传播时延最小）", :shortest_path,
        [:latency, :small_network], [:load_balance],
    ),
    :ecmp => RoutingInfo(
        :ecmp, "ECMP", "等价多路径路由（负载均衡）", :load_balance,
        [:load_balance, :large_network], [:latency],
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

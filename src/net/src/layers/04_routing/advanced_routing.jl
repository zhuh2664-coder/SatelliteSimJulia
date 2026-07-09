# ===== 进阶路由算法 =====
# 基于调研 §6.9 优先级 P1：ECMP + MLB
# 这些算法让路由层从"只有 Dijkstra"变成"可对比多策略"
# 基础是 Graphs.jl 的 yen_k_shortest_paths（K条最短路径）

using Graphs

export ECMPRouting, MinLoadRouting,
       ecmp_paths, min_load_path, k_shortest_paths_with_weights

# ────────────────────────────────────────────────────────────
# 辅助：从边列表构建 Graphs.jl 图 + 权重矩阵
# ────────────────────────────────────────────────────────────

"""
    k_shortest_paths_with_weights(N, edges, weights, src, dst, K) -> Vector{Vector{Int}}

用 Graphs.jl 的 yen_k 算法找 K 条最短路径。
"""
function k_shortest_paths_with_weights(
    N::Int, edges::Vector{Tuple{Int,Int}}, weights::Vector{Float64},
    src::Int, dst::Int, K::Int=3; directed::Bool=true,
)
    length(edges) == length(weights) || throw(ArgumentError("edges and weights must have the same length"))
    g = directed ? SimpleDiGraph(N) : SimpleGraph(N)
    distmx = fill(Inf, N, N)
    for i in eachindex(edges)
        a, b = edges[i]
        1 <= a <= N || throw(ArgumentError("edge source must be in 1:N"))
        1 <= b <= N || throw(ArgumentError("edge destination must be in 1:N"))
        isfinite(weights[i]) || throw(ArgumentError("edge weights must be finite"))
        weights[i] >= 0 || throw(ArgumentError("edge weights must be non-negative"))
        add_edge!(g, a, b)
        distmx[a, b] = min(distmx[a, b], weights[i])
        if !directed
            distmx[b, a] = min(distmx[b, a], weights[i])
        end
    end
    for i in 1:N; distmx[i, i] = 0; end

    result = yen_k_shortest_paths(g, src, dst, distmx, K)
    return result.paths
end

function _path_edge_index(edges::Vector{Tuple{Int,Int}}, u::Int, v::Int; directed::Bool=true)
    return findfirst(
        i -> directed ? edges[i] == (u, v) : (edges[i] == (u, v) || edges[i] == (v, u)),
        eachindex(edges),
    )
end

# ────────────────────────────────────────────────────────────
# ECMP：等价多路径
# ────────────────────────────────────────────────────────────

"""
    ECMPRouting

等价多路径路由策略：在多条等长最短路径间分散流量。
"""
struct ECMPRouting <: AbstractRoutingAlgorithm end

"""
    ecmp_paths(N, edges, weights, src, dst) -> Vector{Vector{Int}}

找出 src→dst 的所有等价（等长）最短路径。
基于 yen_k：取前 K 条，筛出与最短路径等长的。
"""
function ecmp_paths(
    N::Int, edges::Vector{Tuple{Int,Int}}, weights::Vector{Float64},
    src::Int, dst::Int; K::Int=10, directed::Bool=true,
)
    paths = k_shortest_paths_with_weights(N, edges, weights, src, dst, K; directed=directed)
    isempty(paths) && return Vector{Int}[]

    # 算每条路径的总权重
    function path_weight(p)
        w = 0.0
        for i in 1:length(p)-1
            idx = _path_edge_index(edges, p[i], p[i+1]; directed=directed)
            idx === nothing && return Inf
            w += weights[idx]
        end
        return w
    end

    weights_all = [path_weight(p) for p in paths]
    min_w = minimum(weights_all)
    # 等价路径：权重差 < 1e-9（浮点容差）
    return [paths[i] for i in eachindex(paths) if abs(weights_all[i] - min_w) < 1e-9]
end

# ────────────────────────────────────────────────────────────
# MLB：最小负载路径
# ────────────────────────────────────────────────────────────

"""
    MinLoadRouting

最小负载路由策略：选当前链路负载最低的路径。
迭代式：Dijkstra → 累加负载 → 边权改拥塞加权 → 重算。
"""
struct MinLoadRouting <: AbstractRoutingAlgorithm end

# ────────────────────────────────────────────────────────────
# route() 方法：让 ECMP/MinLoad 真正实现 AbstractRoutingAlgorithm 接口
# RoutingInput/RoutingOutput 在同模块（abstract.jl include 进 SatelliteSimNet）
# ────────────────────────────────────────────────────────────

"""
    route(::ECMPRouting, input) -> RoutingOutput

ECMP 路由：从 RoutingGraph 提取边+权重，用 yen_k 找等价最短路径，取第一条。
"""
function route(::ECMPRouting, input::RoutingInput)::RoutingOutput
    g = input.graph
    src, dst = input.source, input.destination
    src == dst && return RoutingOutput([src], 0.0, "ECMP")
    # 从 RoutingGraph 提取边和权重
    edges = Tuple{Int,Int}[]
    weights = Float64[]
    for (u, nbrs) in g.adj
        for (v, w) in nbrs
            push!(edges, (u, v))
            push!(weights, w)
        end
    end
    paths = k_shortest_paths_with_weights(g.n_nodes, edges, weights, src, dst, 10)
    isempty(paths) && return RoutingOutput(Int[], Inf, "ECMP-unreachable")
    # 算每条路径权重，取等价最短的。RoutingGraph.adj 语义保持有向。
    function path_weight(path)
        total = 0.0
        for k in 1:length(path)-1
            idx = _path_edge_index(edges, path[k], path[k+1])
            idx === nothing && return Inf
            total += weights[idx]
        end
        return total
    end
    ws = path_weight.(paths)
    min_w = minimum(ws)
    best = paths[argmin(ws)]
    return RoutingOutput(best, min_w, "ECMP")
end

"""
    route(::MinLoadRouting, input) -> RoutingOutput

MinLoad 路由：无实时负载信息时退化为最短路径（与 Dijkstra 等价）。
有负载信息时应配合 current_loads/capacities 使用 min_load_path。
"""
function route(::MinLoadRouting, input::RoutingInput)::RoutingOutput
    src, dst = input.source, input.destination
    src == dst && return RoutingOutput([src], 0.0, "MinLoad")
    # 无负载信息 → 退化为有向加权最短路；保持 RoutingGraph.adj 的方向和权重语义。
    A = _routing_graph_adjacency_matrix(input.graph)
    path, cost = shortest_path_from_adjacency(A, src, dst)
    isempty(path) && return RoutingOutput(Int[], Inf, "MinLoad-unreachable")
    return RoutingOutput(path, cost, "MinLoad")
end

"""
    min_load_path(N, edges, weights, src, dst, demands, current_loads) -> Vector{Int}

给定当前各链路负载，选负载最轻的路径。
边权 = 基础时延 × (1 + load/capacity)（拥塞感知）。
"""
function min_load_path(
    N::Int, edges::Vector{Tuple{Int,Int}}, weights::Vector{Float64},
    src::Int, dst::Int,
    current_loads::Vector{Float64}, capacities::Vector{Float64};
    K::Int=5, directed::Bool=true,
)
    length(edges) == length(weights) == length(current_loads) == length(capacities) ||
        throw(ArgumentError("edges, weights, current_loads, and capacities must have the same length"))
    # 拥塞感知边权：负载越高权重越大
    congestion_weights = [weights[i] * (1 + current_loads[i] / max(capacities[i], 1e-6)) for i in eachindex(edges)]

    paths = k_shortest_paths_with_weights(N, edges, congestion_weights, src, dst, K; directed=directed)
    isempty(paths) && return Int[]

    # 选拥塞感知权重最小的
    function path_congestion(p)
        w = 0.0
        for i in 1:length(p)-1
            idx = _path_edge_index(edges, p[i], p[i+1]; directed=directed)
            idx === nothing && return Inf
            w += congestion_weights[idx]
        end
        return w
    end

    cong = [path_congestion(p) for p in paths]
    return paths[argmin(cong)]
end

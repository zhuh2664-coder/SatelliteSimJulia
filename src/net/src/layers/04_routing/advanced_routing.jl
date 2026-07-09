# ===== 进阶路由算法 =====
# 基于调研 §6.9 优先级 P1：ECMP + MLB
# 这些算法让路由层从"只有 Dijkstra"变成"可对比多策略"
# 基础是 Graphs.jl 的 yen_k_shortest_paths（K条最短路径）

using Graphs

export ECMPRouting, MinLoadRouting,
       ecmp_paths, min_load_path, k_shortest_paths_with_weights

# ────────────────────────────────────────────────────────────
# 辅助：从邻接矩阵构建 SimpleGraph + 权重矩阵
# ────────────────────────────────────────────────────────────

"""
    k_shortest_paths_with_weights(N, edges, weights, src, dst, K) -> Vector{Vector{Int}}

用 Graphs.jl 的 yen_k 算法找 K 条最短路径。
"""
function k_shortest_paths_with_weights(
    N::Int, edges::Vector{Tuple{Int,Int}}, weights::Vector{Float64},
    src::Int, dst::Int, K::Int=3,
)
    g = SimpleGraph(N)
    distmx = fill(Inf, N, N)
    for i in eachindex(edges)
        a, b = edges[i]
        add_edge!(g, a, b)
        distmx[a, b] = weights[i]
        distmx[b, a] = weights[i]
    end
    for i in 1:N; distmx[i, i] = 0; end

    result = yen_k_shortest_paths(g, src, dst, distmx, K)
    return result.paths
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
    src::Int, dst::Int; K::Int=10,
)
    paths = k_shortest_paths_with_weights(N, edges, weights, src, dst, K)
    isempty(paths) && return Vector{Int}[]

    # 算每条路径的总权重
    function path_weight(p)
        w = 0.0
        for i in 1:length(p)-1
            idx = findfirst(j -> edges[j] == (p[i], p[i+1]) || edges[j] == (p[i+1], p[i]), eachindex(edges))
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

**注意**：`route(::MinLoadRouting, ::RoutingInput)` 不含实时 `current_loads` 时，
会发出一次性运行时警告，并退化为基于 `RoutingGraph` 静态边权的最短路（与 Dijkstra 等价）。
有负载数据时请直接调用 `min_load_path(..., current_loads, capacities)`。
"""
struct MinLoadRouting <: AbstractRoutingAlgorithm end

const _MINLOAD_STATIC_FALLBACK_WARNED = Ref(false)

function _warn_once(ref::Ref{Bool}, msg::String)
    if !ref[]
        ref[] = true
        printstyled(stderr, "[MinLoadRouting] ", msg, "\n"; color = :yellow)
    end
end

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
    # 从 RoutingGraph 提取无向边和权重（去重）
    edges = Tuple{Int,Int}[]
    weights = Float64[]
    seen = Set{Tuple{Int,Int}}()
    for (u, nbrs) in g.adj
        for (v, w) in nbrs
            canonical = u < v ? (u, v) : (v, u)
            canonical in seen && continue
            push!(seen, canonical)
            push!(edges, canonical)
            push!(weights, w)
        end
    end
    paths = k_shortest_paths_with_weights(g.n_nodes, edges, weights, src, dst, 10)
    isempty(paths) && return RoutingOutput(Int[], Inf, "ECMP-unreachable")
    # 算每条路径权重，取等价最短的
    w(p) = let s=0.0
        for k in 1:length(p)-1
            idx = findfirst(j -> edges[j]==(p[k],p[k+1]) || edges[j]==(p[k+1],p[k]), eachindex(edges))
            idx === nothing && return Inf
            s += weights[idx]
        end; s
    end
    ws = w.(paths)
    min_w = minimum(ws)
    best = paths[argmin(ws)]
    return RoutingOutput(best, min_w, "ECMP")
end

function _extract_graph_edges(g::RoutingGraph)
    edges = Tuple{Int,Int}[]
    weights = Float64[]
    seen = Set{Tuple{Int,Int}}()
    for (u, nbrs) in g.adj
        for (v, w) in nbrs
            canonical = u < v ? (u, v) : (v, u)
            canonical in seen && continue
            push!(seen, canonical)
            push!(edges, canonical)
            push!(weights, w)
        end
    end
    return edges, weights
end

"""
    route(::MinLoadRouting, input) -> RoutingOutput

MinLoad 路由：有 `current_loads`/`capacities` 时用拥塞感知 `min_load_path`；
否则退化为静态权重最短路（Dijkstra 等价）。
"""
function route(::MinLoadRouting, input::RoutingInput)::RoutingOutput
    g = input.graph
    src, dst = input.source, input.destination
    src == dst && return RoutingOutput([src], 0.0, "MinLoad")

    if input.current_loads !== nothing && input.capacities !== nothing
        edges, weights = _extract_graph_edges(g)
        loads = input.current_loads
        caps = input.capacities
        length(loads) == length(edges) ||
            throw(ArgumentError("current_loads length must match graph edge count"))
        length(caps) == length(edges) ||
            throw(ArgumentError("capacities length must match graph edge count"))
        path = min_load_path(g.n_nodes, edges, weights, src, dst, loads, caps)
        isempty(path) && return RoutingOutput(Int[], Inf, "MinLoad-unreachable")
        cost = let s = 0.0
            for k in 1:length(path)-1
                idx = findfirst(j -> edges[j] == (path[k], path[k+1]) || edges[j] == (path[k+1], path[k]), eachindex(edges))
                idx === nothing && return RoutingOutput(Int[], Inf, "MinLoad-unreachable")
                cw = weights[idx] * (1 + loads[idx] / max(caps[idx], 1e-6))
                s += cw
            end
            s
        end
        return RoutingOutput(path, cost, "MinLoad-congestion")
    end

    if !_MINLOAD_STATIC_FALLBACK_WARNED[]
        _warn_once(_MINLOAD_STATIC_FALLBACK_WARNED,
            "无实时链路负载，退化为静态权重最短路（Dijkstra）。有负载时请传入 RoutingInput(..., current_loads=..., capacities=...)。")
    end
    distmx = fill(Inf, g.n_nodes, g.n_nodes)
    for i in 1:g.n_nodes
        distmx[i, i] = 0.0
        for (v, w) in g.adj[i]
            distmx[i, v] = w
        end
    end
    path, cost = shortest_path_from_adjacency(distmx, src, dst)
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
    K::Int=5,
)
    # 拥塞感知边权：负载越高权重越大
    congestion_weights = [weights[i] * (1 + current_loads[i] / max(capacities[i], 1e-6)) for i in eachindex(edges)]

    paths = k_shortest_paths_with_weights(N, edges, congestion_weights, src, dst, K)
    isempty(paths) && return Int[]

    # 选拥塞感知权重最小的
    function path_congestion(p)
        w = 0.0
        for i in 1:length(p)-1
            idx = findfirst(j -> edges[j] == (p[i], p[i+1]) || edges[j] == (p[i+1], p[i]), eachindex(edges))
            idx === nothing && return Inf
            w += congestion_weights[idx]
        end
        return w
    end

    cong = [path_congestion(p) for p in paths]
    return paths[argmin(cong)]
end

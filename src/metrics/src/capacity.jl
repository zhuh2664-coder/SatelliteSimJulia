# ===== 网络容量分析 =====
# 贪心带宽分配，参考 MOST 论文 Section VI-B。
#
# 论文方法（简化）：
#   1. 给定网络拓扑和源-目的卫星对
#   2. 每条 ISL 有固定容量（如 1 Gbps = 1000 Mbps）
#   3. 轮询方式对每对源-目的加 step_mbps
#   4. 检查最短路径上每条链路是否超容量
#   5. 直到任何一对都无法再加 → 总容量 = 所有已分配带宽之和

using Graphs
using Statistics: mean

export NetworkCapacityResult, compute_network_capacity,
       worst_case_city_matching

"""
    NetworkCapacityResult

贪心带宽分配结果。

# 字段
- `total_capacity_gbps::Float64`: 总容量 (Gbps)
- `allocations::Vector{Float64}`: 每对源-目的分配的带宽 (Mbps)
- `num_pairs::Int`: 源-目的对数
- `saturated_links::Int`: 被占满的链路数
- `avg_allocation_mbps::Float64`: 平均每对分配带宽
"""
struct NetworkCapacityResult
    total_capacity_gbps::Float64
    allocations::Vector{Float64}
    num_pairs::Int
    saturated_links::Int
    avg_allocation_mbps::Float64
end

"""
    compute_network_capacity(g, pairs; link_capacity_mbps, step_mbps)
        -> NetworkCapacityResult

贪心轮询带宽分配。对每对 (src, dst) 循环加 step_mbps，
每次检查最短路径上所有链路剩余容量是否足够。

# 参数
- `g::Graphs.SimpleGraph`: 网络拓扑图（无向）
- `pairs::Vector{Tuple{Int,Int}}`: 源-目的卫星对
- `link_capacity_mbps::Float64=1000.0`: 每条 ISL 容量 (Mbps), 论文默认 1 Gbps
- `step_mbps::Float64=100.0`: 每轮增量 (Mbps)
"""
function compute_network_capacity(
    g::Graphs.SimpleGraph,
    pairs::Vector{Tuple{Int,Int}};
    link_capacity_mbps::Float64=1000.0,
    step_mbps::Float64=100.0,
)::NetworkCapacityResult
    n_pairs = length(pairs)
    n_pairs == 0 && return NetworkCapacityResult(0.0, Float64[], 0, 0, 0.0)

    # 1. 预计算每条 pair 的最短路径（边列表）
    pair_paths = Vector{Vector{Graphs.SimpleEdge{Int}}}(undef, n_pairs)
    pair_valid = Vector{Bool}(undef, n_pairs)
    for (k, (src, dst)) in enumerate(pairs)
        state = Graphs.dijkstra_shortest_paths(g, src)
        if state.dists[dst] == typemax(Int)
            pair_paths[k] = Graphs.SimpleEdge{Int}[]
            pair_valid[k] = false
        else
            # 获取最短路径上的边
            path_edges = Graphs.SimpleEdge{Int}[]
            v = dst
            while v != src
                u = state.parents[v]
                u == 0 && break
                push!(path_edges, Graphs.SimpleEdge(min(u, v), max(u, v)))
                v = u
            end
            pair_paths[k] = path_edges
            pair_valid[k] = true
        end
    end

    # 2. 链路容量追踪 (edge -> remaining_capacity)
    edge_cap = Dict{Graphs.SimpleEdge{Int},Float64}()
    for e in Graphs.edges(g)
        edge_cap[e] = link_capacity_mbps
    end

    # 3. 贪心轮询分配
    allocations = zeros(n_pairs)
    improved = true
    while improved
        improved = false
        for k in 1:n_pairs
            pair_valid[k] || continue
            path = pair_paths[k]
            isempty(path) && continue

            # 检查路径上所有链路的剩余容量
            can_allocate = true
            for e in path
                cap = get(edge_cap, e, link_capacity_mbps)
                if cap < step_mbps
                    can_allocate = false
                    break
                end
            end

            can_allocate || continue
            # 分配
            for e in path
                edge_cap[e] = get(edge_cap, e, link_capacity_mbps) - step_mbps
            end
            allocations[k] += step_mbps
            improved = true
        end
    end

    # 4. 统计
    saturated = 0
    for (_, cap) in edge_cap
        cap < step_mbps && (saturated += 1)
    end

    # total_capacity = sum of carried bandwidth across all pairs
    total_mbps = sum(allocations)
    avg_mbps = total_mbps / n_pairs

    return NetworkCapacityResult(
        total_mbps / 1000.0,  # Gbps
        allocations,
        n_pairs,
        saturated,
        avg_mbps,
    )
end

"""
    worst_case_city_matching(g, city_visible_sats; max_pairs) -> Vector{Tuple{Int,Int}}

构建 near worst-case 城市匹配：最大化平均跳数，使流量经过更多跳。

论文 Section VI-B：最大化平均跳数来构造最坏流量矩阵，测试网络容量下界。

# 参数
- `g::Graphs.SimpleGraph`: 网络拓扑图
- `city_visible_sats::Vector{Vector{Int}}`: 每个城市的可见卫星列表
- `max_pairs::Int=15`: 最多返回多少对

# 返回
城市索引对列表 [(city_i, city_j), ...]，对应城市间的卫星通信对。
"""
function worst_case_city_matching(
    g::Graphs.SimpleGraph,
    city_visible_sats::Vector{Vector{Int}};
    max_pairs::Int=15,
)
    n_cities = length(city_visible_sats)
    # 计算城市间平均跳数
    city_hops = zeros(n_cities, n_cities)
    for ci in 1:n_cities, cj in (ci+1):n_cities
        vi, vj = city_visible_sats[ci], city_visible_sats[cj]
        (isempty(vi) || isempty(vj)) && continue
        min_hops = typemax(Int)
        for si in vi, sj in vj
            state = Graphs.dijkstra_shortest_paths(g, si)
            h = state.dists[sj]
            h < min_hops && (min_hops = h)
        end
        city_hops[ci, cj] = min_hops < typemax(Int) ? min_hops : 0
        city_hops[cj, ci] = city_hops[ci, cj]
    end

    # 贪心匹配：每次选跳数最大的城市对
    used = falses(n_cities)
    result = Tuple{Int,Int}[]
    remaining = collect(1:n_cities)

    for _ in 1:max_pairs
        best_hop, best_pair = 0, (0, 0)
        for ci in remaining
            used[ci] && continue
            for cj in remaining
                used[cj] && continue
                ci == cj && continue
                h = city_hops[ci, cj]
                h > best_hop && (best_hop = h; best_pair = (ci, cj))
            end
        end
        best_hop == 0 && break
        push!(result, best_pair)
        used[best_pair[1]] = used[best_pair[2]] = true
    end

    return result
end

"""
    compute_network_capacity_for_cities(g, sat_positions, cities, constraints;
                                         top_k, link_capacity_mbps, step_mbps,
                                         pair_builder)
        -> (NetworkCapacityResult, Vector{Tuple{Int,Int}})

一站式：从城市数据直接算网络容量。Core 不依赖实验层，城市配对逻辑由调用方显式传入。
"""
function compute_network_capacity_for_cities(
    g::Graphs.SimpleGraph,
    sat_positions::Matrix{Float64},
    cities::Vector,
    constraints;
    top_k::Int=3,
    link_capacity_mbps::Float64=1000.0,
    step_mbps::Float64=100.0,
    pair_builder=nothing,
)
    pair_builder === nothing && throw(ArgumentError(
        "compute_network_capacity_for_cities requires pair_builder; pass a city-to-satellite pair builder from the experiment layer or call compute_network_capacity with precomputed satellite pairs."
    ))

    gs_pairs = pair_builder(sat_positions, cities, constraints; top_k=top_k)

    result = compute_network_capacity(g, gs_pairs;
        link_capacity_mbps=link_capacity_mbps, step_mbps=step_mbps)
    return result, gs_pairs
end

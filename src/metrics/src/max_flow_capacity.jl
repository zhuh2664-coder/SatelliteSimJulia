# ===== 网络容量分析：最大流上界 =====
#
# 贪心版 compute_network_capacity（capacity.jl）用单条固定最短路逐对加带宽，
# 一旦该路饱和即停，即使存在其它不相交路径也不改道 —— 是网络容量的**下界**。
#
# 本文件提供**上界**：对每个源-目的对，在容量化的 ISL 图上求单商品最大流
# （Edmonds-Karp / BFS 增广），允许多路径与改道。两者夹出真实可承载容量区间：
#   greedy(下界)  ≤  真实多商品容量  ≤  Σ per-pair max-flow(上界)
#
# 建模：ISL 链路视为无向、容量 link_capacity_mbps；每对独立求单商品 s-t 最大流，
# 聚合上界为各对最大流之和（忽略对间竞争，故为上界）。
#
# 新增于 2026-07-08（发表级容量口径补全）。

export NetworkMaxFlowCapacityResult, max_flow_value, compute_network_capacity_maxflow

"""
    NetworkMaxFlowCapacityResult

单商品最大流容量（上界）结果。

# 字段
- `total_capacity_gbps::Float64`: 各对最大流之和 (Gbps)，网络容量上界
- `per_pair_mbps::Vector{Float64}`: 每对源-目的的单商品最大流 (Mbps)
- `num_pairs::Int`: 源-目的对数
- `min_pair_mbps::Float64`: 最小单对最大流 (Mbps)
- `mean_pair_mbps::Float64`: 平均单对最大流 (Mbps)
"""
struct NetworkMaxFlowCapacityResult
    total_capacity_gbps::Float64
    per_pair_mbps::Vector{Float64}
    num_pairs::Int
    min_pair_mbps::Float64
    mean_pair_mbps::Float64
end

"""
    max_flow_value(n, edges, capacities, source, sink) -> Float64

在无向容量图上求 source→sink 的单商品最大流值（Edmonds-Karp，O(V·E²)）。

# 参数
- `n::Int`: 节点数（节点编号 1..n）
- `edges::Vector{Tuple{Int,Int}}`: 无向边列表
- `capacities::Vector{Float64}`: 每条边容量（与 edges 等长，Mbps）
- `source::Int` / `sink::Int`: 源、汇节点

平行边容量累加；边视为无向（两方向共享容量）。source==sink 返回 0。
"""
function max_flow_value(
    n::Int,
    edges::Vector{Tuple{Int,Int}},
    capacities::Vector{Float64},
    source::Int,
    sink::Int,
)::Float64
    (source == sink || n == 0) && return 0.0
    length(edges) == length(capacities) ||
        throw(ArgumentError("edges and capacities must have equal length"))
    (1 <= source <= n && 1 <= sink <= n) ||
        throw(ArgumentError("source/sink out of range"))

    # 残量矩阵（无向：两方向都置容量，平行边累加）
    residual = zeros(Float64, n, n)
    for (idx, (u, v)) in enumerate(edges)
        (1 <= u <= n && 1 <= v <= n) || continue
        u == v && continue
        c = capacities[idx]
        residual[u, v] += c
        residual[v, u] += c
    end

    total = 0.0
    parent = zeros(Int, n)
    while true
        # BFS 找一条 source→sink 的增广路（残量 > 0）
        fill!(parent, 0)
        parent[source] = source
        queue = Int[source]
        head = 1
        while head <= length(queue)
            u = queue[head]; head += 1
            u == sink && break
            for v in 1:n
                if parent[v] == 0 && residual[u, v] > 0
                    parent[v] = u
                    push!(queue, v)
                end
            end
        end
        parent[sink] == 0 && break  # 无增广路

        # 沿增广路求瓶颈
        bottleneck = Inf
        v = sink
        while v != source
            u = parent[v]
            bottleneck = min(bottleneck, residual[u, v])
            v = u
        end
        # 更新残量
        v = sink
        while v != source
            u = parent[v]
            residual[u, v] -= bottleneck
            residual[v, u] += bottleneck
            v = u
        end
        total += bottleneck
    end
    return total
end

"""
    compute_network_capacity_maxflow(n, edges, capacities, pairs) -> NetworkMaxFlowCapacityResult

对每对源-目的求单商品最大流，聚合为网络容量上界。

# 参数
- `n::Int`: 节点数
- `edges::Vector{Tuple{Int,Int}}`: 无向 ISL 边列表
- `capacities::Vector{Float64}`: 每条边容量 (Mbps)
- `pairs::Vector{Tuple{Int,Int}}`: 源-目的卫星对

# 说明
聚合上界 = Σ per-pair max-flow，忽略对间容量竞争，故为**上界**；
与 `compute_network_capacity`（贪心下界）配合，夹出真实容量区间。
"""
function compute_network_capacity_maxflow(
    n::Int,
    edges::Vector{Tuple{Int,Int}},
    capacities::Vector{Float64},
    pairs::Vector{Tuple{Int,Int}},
)::NetworkMaxFlowCapacityResult
    n_pairs = length(pairs)
    n_pairs == 0 && return NetworkMaxFlowCapacityResult(0.0, Float64[], 0, 0.0, 0.0)

    per_pair = Vector{Float64}(undef, n_pairs)
    for (i, (src, dst)) in enumerate(pairs)
        per_pair[i] = max_flow_value(n, edges, capacities, src, dst)
    end

    total_mbps = sum(per_pair)
    return NetworkMaxFlowCapacityResult(
        total_mbps / 1000.0,
        per_pair,
        n_pairs,
        minimum(per_pair),
        total_mbps / n_pairs,
    )
end

"""
    compute_network_capacity_maxflow(g, pairs; link_capacity_mbps) -> NetworkMaxFlowCapacityResult

便捷重载：从 `Graphs.SimpleGraph` 构造等容量边列表后求最大流上界。
"""
function compute_network_capacity_maxflow(
    g::Graphs.SimpleGraph,
    pairs::Vector{Tuple{Int,Int}};
    link_capacity_mbps::Float64 = 1000.0,
)::NetworkMaxFlowCapacityResult
    edges = Tuple{Int,Int}[(Graphs.src(e), Graphs.dst(e)) for e in Graphs.edges(g)]
    caps = fill(link_capacity_mbps, length(edges))
    return compute_network_capacity_maxflow(Graphs.nv(g), edges, caps, pairs)
end

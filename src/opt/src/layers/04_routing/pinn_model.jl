# ===== PINN 路由模型 — 神经网络 + 特征编码 =====

export create_pinn_model, encode_routing_features, reset_pinn_bfs_cache!

const CACHE_BFS = Dict{Tuple{Int,Int,Int},Int}()

"""清空 BFS 跳数缓存（拓扑变化后调用）。"""
reset_pinn_bfs_cache!() = empty!(CACHE_BFS)

"""
create_pinn_model(input_dim, hidden_dim) -> Lux.Chain

构建一个 MLP 用于学习 `(features) → latency` 映射。

结构:
  Input(input_dim) → Dense(hidden_dim, tanh) → Dense(hidden_dim, tanh)
  → Dense(hidden_dim, tanh) → Dense(1)

~8K 参数 (hidden_dim=64), 适合快速推理。
"""
function create_pinn_model(input_dim::Int, hidden_dim::Int=64)
    return Lux.Chain(
        Lux.Dense(input_dim, hidden_dim, Lux.tanh),
        Lux.Dense(hidden_dim, hidden_dim, Lux.tanh),
        Lux.Dense(hidden_dim, hidden_dim, Lux.tanh),
        Lux.Dense(hidden_dim, 1),
    )
end

"""
    encode_routing_features(adj, src, dst) -> Vector{Float64}

将路由问题编码为定长特征向量。

特征设计（12维，与星座规模无关）:
  [1]   hop_dist: BFS 最短跳数 (src→dst)
  [2]   src_degree: src 的度
  [3]   dst_degree: dst 的度
  [4]   same_plane: 是否在同一轨道面
  [5]   src_plane_idx: src 轨道面索引 (归一化)
  [6]   dst_plane_idx: dst 轨道面索引 (归一化)
  [7]   n_sats: 卫星总数 (归一化)
  [8]   src_local_density: src 的 2 跳邻居数
  [9]   dst_local_density: dst 的 2 跳邻居数
  [10]  avg_neighbor_deg_src: src 邻居的平均度
  [11]  avg_neighbor_deg_dst: dst 邻居的平均度
  [12]  cross_plane: src 和 dst 是否跨轨道面
"""
function encode_routing_features(
    adj::Matrix{Float64},
    src::Int,
    dst::Int,
    sats_per_plane::Int=72,
    n_planes::Int=6,
)
    N = size(adj, 1)

    # 1. BFS 最短跳数 (拓扑距离, 不受边权影响)
    hop_dist = bfs_hop_count(adj, src, dst)

    # 2–3. 度
    src_deg = count(isfinite, adj[src, :]) - 1
    dst_deg = count(isfinite, adj[dst, :]) - 1

    # 4, 12. 轨道面
    src_plane = div(src - 1, sats_per_plane) + 1
    dst_plane = div(dst - 1, sats_per_plane) + 1
    same_plane = src_plane == dst_plane

    # 5–6. 归一化轨道面索引
    src_plane_norm = (src_plane - 1) / max(n_planes - 1, 1)
    dst_plane_norm = (dst_plane - 1) / max(n_planes - 1, 1)

    # 7. 卫星总数归一化
    n_norm = N / 1000.0

    # 8–9. 2 跳邻居密度
    src_density = count(isfinite, (adj * adj)[src, :]) - 1
    dst_density = count(isfinite, (adj * adj)[dst, :]) - 1
    src_density_norm = src_density / max(N, 1)
    dst_density_norm = dst_density / max(N, 1)

    # 10–11. 邻居平均度
    avg_nd_src = mean_degree_of_neighbors(adj, src)
    avg_nd_dst = mean_degree_of_neighbors(adj, dst)

    return Float64[
        Float64(hop_dist) / max(N, 1),
        src_deg / max(N, 1),
        dst_deg / max(N, 1),
        same_plane ? 1.0 : 0.0,
        src_plane_norm,
        dst_plane_norm,
        n_norm,
        src_density_norm,
        dst_density_norm,
        avg_nd_src / max(N, 1),
        avg_nd_dst / max(N, 1),
        same_plane ? 0.0 : 1.0,
    ]
end

"""
    bfs_hop_count(adj, src, dst) -> Int

BFS 找最短路径跳数（无权图）。缓存结果避免重复计算。
"""
function bfs_hop_count(adj::Matrix{Float64}, src::Int, dst::Int)::Int
    key = (size(adj, 1), src, dst)
    haskey(CACHE_BFS, key) && return CACHE_BFS[key]

    N = size(adj, 1)
    dist = fill(-1, N)
    dist[src] = 0
    queue = [src]

    while !isempty(queue)
        u = popfirst!(queue)
        u == dst && break
        for v in 1:N
            if isfinite(adj[u, v]) && v != u && dist[v] < 0
                dist[v] = dist[u] + 1
                push!(queue, v)
            end
        end
    end

    result = dist[dst] < 0 ? N : dist[dst]
    CACHE_BFS[key] = result
    return result
end

"""
    mean_degree_of_neighbors(adj, node) -> Float64

返回 node 邻居的平均度。
"""
function mean_degree_of_neighbors(adj::Matrix{Float64}, node::Int)::Float64
    N = size(adj, 1)
    total_deg = 0.0
    n_nbrs = 0
    for v in 1:N
        if isfinite(adj[node, v]) && v != node
            deg = count(isfinite, adj[v, :]) - 1
            total_deg += deg
            n_nbrs += 1
        end
    end
    return n_nbrs > 0 ? total_deg / n_nbrs : 0.0
end

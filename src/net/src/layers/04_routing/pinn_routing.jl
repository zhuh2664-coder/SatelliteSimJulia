export PINNRoutingAlgorithm, routing_graph_to_adjacency_matrix,
       pinn_predict_all_pairs

struct PINNRoutingAlgorithm{P, F} <: AbstractRoutingAlgorithm
    pinn::P
    predict::F
    sats_per_plane::Int
    n_planes::Int
end

function PINNRoutingAlgorithm(pinn, predict; sats_per_plane=72, n_planes=6)
    return PINNRoutingAlgorithm(pinn, predict, sats_per_plane, n_planes)
end

function routing_graph_to_adjacency_matrix(g::RoutingGraph)::Matrix{Float64}
    N = g.n_nodes
    A = fill(Inf, N, N)
    for i in 1:N
        A[i, i] = 0.0
    end
    for (i, neighbors) in g.adj
        for (j, w) in neighbors
            A[i, j] = w
        end
    end
    return A
end

"""
    route(alg::PINNRoutingAlgorithm, input) -> RoutingOutput

PINN 路由：用 PINN 预测端到端时延，并在同一邻接矩阵上用 Dijkstra 重建具体路径。

# 返回
`RoutingOutput` 中：
- `path`：Dijkstra 在邻接矩阵上求得的最短路径（节点序列），供下游实际转发使用；
  若 src→dst 不连通则为空 `Int[]`，算法名标记为 `"PINNRouting-unreachable"`。
- `total_weight`：**PINN 预测的时延**（而非 Dijkstra 路径的累加权重），
  即本算法的核心产物；路径仅用于给出一条可用路由。

此前实现只返回预测时延、`path` 恒为空，下游拿不到可转发的路径；这里补上路径重建。
"""
function route(alg::PINNRoutingAlgorithm, input::RoutingInput)::RoutingOutput
    adj = routing_graph_to_adjacency_matrix(input.graph)
    src, dst = input.source, input.destination

    if src == dst
        return RoutingOutput([src], 0.0, "PINNRouting")
    end

    latency_ms = alg.predict(alg.pinn, adj, src, dst)
    # 用同一邻接矩阵上的 Dijkstra 重建具体路径（shortest_path_from_adjacency
    # 定义于 dijkstra.jl，同模块内先于本文件 include）。
    path, _ = shortest_path_from_adjacency(adj, src, dst)
    isempty(path) && return RoutingOutput(Int[], Float64(latency_ms), "PINNRouting-unreachable")
    return RoutingOutput(path, Float64(latency_ms), "PINNRouting")
end

function pinn_predict_all_pairs(alg::PINNRoutingAlgorithm, adj::Matrix{Float64})::Matrix{Float64}
    N = size(adj, 1)
    result = zeros(N, N)

    for src in 1:N
        for dst in 1:N
            if src == dst
                result[src, dst] = 0.0
            else
                result[src, dst] = alg.predict(alg.pinn, adj, src, dst)
            end
        end
    end

    return result
end

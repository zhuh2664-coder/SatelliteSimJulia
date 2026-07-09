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

function route(alg::PINNRoutingAlgorithm, input::RoutingInput)::RoutingOutput
    adj = routing_graph_to_adjacency_matrix(input.graph)
    src, dst = input.source, input.destination

    if src == dst
        return RoutingOutput([src], 0.0, "PINNRouting")
    end

    latency_ms = alg.predict(alg.pinn, adj, src, dst)
    fallback = route(DijkstraRouting(), input)
    if isempty(fallback.path)
        return RoutingOutput(Int[], Inf, "PINNRouting-unreachable")
    end
    cost = isfinite(latency_ms) && latency_ms >= 0 ? Float64(latency_ms) : fallback.total_weight
    return RoutingOutput(fallback.path, cost, "PINNRouting")
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

# Dijkstra 最短路径路由。

export DijkstraRouting, build_adjacency, all_pairs_shortest_paths,
       shortest_path_from_adjacency

struct DijkstraRouting <: AbstractRoutingAlgorithm end

function _routing_graph_adjacency_matrix(graph::RoutingGraph)::Matrix{Float64}
    A = fill(Inf, graph.n_nodes, graph.n_nodes)
    for i in 1:graph.n_nodes
        A[i, i] = 0.0
    end
    for (u, neighbors) in graph.adj
        1 <= u <= graph.n_nodes || throw(ArgumentError("edge source must be in 1:n_nodes"))
        for (v, weight) in neighbors
            1 <= v <= graph.n_nodes || throw(ArgumentError("edge destination must be in 1:n_nodes"))
            isfinite(weight) || throw(ArgumentError("edge weights must be finite"))
            weight >= 0 || throw(ArgumentError("edge weights must be non-negative"))
            A[u, v] = min(A[u, v], Float64(weight))
        end
    end
    return A
end

function route(::DijkstraRouting, input::RoutingInput)::RoutingOutput
    src = input.source
    dst = input.destination
    src == dst && return RoutingOutput([src], 0.0, "Dijkstra")

    A = _routing_graph_adjacency_matrix(input.graph)
    path, cost = shortest_path_from_adjacency(A, src, dst)
    isempty(path) && return RoutingOutput(Int[], Inf, "Dijkstra-unreachable")
    return RoutingOutput(path, cost, "Dijkstra")
end

function build_adjacency(N::Int, edges::Vector{Tuple{Int,Int}}, weights::Vector{Float64})
    A = fill(Inf, N, N)
    for i in 1:N; A[i, i] = 0.0; end
    for (k, (i, j)) in enumerate(edges)
        A[i, j] = A[j, i] = weights[k]
    end
    return A
end

function all_pairs_shortest_paths(A::Matrix{Float64})
    N = size(A, 1)
    D = copy(A)
    for k in 1:N, i in 1:N, j in 1:N
        nd = D[i, k] + D[k, j]
        if nd < D[i, j]
            D[i, j] = nd
        end
    end
    return D
end

function shortest_path_from_adjacency(A::Matrix{Float64}, source::Int, destination::Int)
    N = size(A, 1)
    1 <= source <= N || throw(ArgumentError("source must be in 1:N"))
    1 <= destination <= N || throw(ArgumentError("destination must be in 1:N"))

    distances = fill(Inf, N)
    previous = zeros(Int, N)
    visited = falses(N)
    distances[source] = 0.0

    for _ in 1:N
        current = 0
        best_distance = Inf
        for node in 1:N
            if !visited[node] && distances[node] < best_distance
                current = node
                best_distance = distances[node]
            end
        end

        current == 0 && break
        current == destination && break
        visited[current] = true

        for neighbor in 1:N
            if !visited[neighbor] && isfinite(A[current, neighbor])
                candidate = distances[current] + A[current, neighbor]
                if candidate < distances[neighbor]
                    distances[neighbor] = candidate
                    previous[neighbor] = current
                end
            end
        end
    end

    isfinite(distances[destination]) || return Int[], Inf

    path = Int[]
    node = destination
    while node != 0
        pushfirst!(path, node)
        node == source && break
        node = previous[node]
    end

    return first(path) == source ? path : Int[], distances[destination]
end

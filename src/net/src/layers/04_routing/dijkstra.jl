# Dijkstra 最短路径路由。

export DijkstraRouting, build_adjacency, all_pairs_shortest_paths,
       shortest_path_from_adjacency

struct DijkstraRouting <: AbstractRoutingAlgorithm end

function route(::DijkstraRouting, input::RoutingInput)::RoutingOutput
    g = input.graph.g
    src = input.source
    dst = input.destination

    state = Graphs.dijkstra_shortest_paths(g, src, Graphs.weights(g))
    # Graphs.jl 用 has_path 判可达（is_reachable 不存在，pre-existing bug 修复）
    if isfinite(state.dists[dst]) && state.dists[dst] < Inf
        # 用 enumerate_paths 从 parents 重建路径
        path = Graphs.enumerate_paths(state, dst)
        return RoutingOutput(path, state.dists[dst], "Dijkstra")
    else
        return RoutingOutput(Int[], Inf, "Dijkstra-unreachable")
    end
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

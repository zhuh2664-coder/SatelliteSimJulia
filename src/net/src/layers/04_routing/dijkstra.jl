# Dijkstra 最短路径路由。

export DijkstraRouting, build_adjacency, build_routing_graph, all_pairs_shortest_paths,
       shortest_path_from_adjacency

struct DijkstraRouting <: AbstractRoutingAlgorithm end

"""
    build_routing_graph(n_nodes, edges, weights; node_labels) -> RoutingGraph

从边列表与权重构造 `RoutingGraph`，供 `route(DijkstraRouting(), RoutingInput(...))` 使用。
无向 ISL：每条边双向写入邻接表与 `SimpleDiGraph`。
"""
function build_routing_graph(
    n_nodes::Int,
    edges::Vector{Tuple{Int,Int}},
    weights::Vector{Float64};
    node_labels::Vector{String} = String[],
)::RoutingGraph
    length(edges) == length(weights) ||
        throw(ArgumentError("edges and weights must have the same length"))
    if isempty(node_labels)
        node_labels = ["node$i" for i in 1:n_nodes]
    else
        length(node_labels) == n_nodes ||
            throw(ArgumentError("node_labels length must equal n_nodes"))
    end

    g = SimpleDiGraph(n_nodes)
    adj = Dict{Int, Vector{Tuple{Int, Float64}}}()
    for i in 1:n_nodes
        adj[i] = Tuple{Int, Float64}[]
    end

    seen = Set{Tuple{Int, Int}}()
    for (k, (u, v)) in enumerate(edges)
        (1 <= u <= n_nodes && 1 <= v <= n_nodes) ||
            throw(ArgumentError("edge ($u, $v) out of range 1:$n_nodes"))
        canonical = u < v ? (u, v) : (v, u)
        canonical in seen && continue
        push!(seen, canonical)
        w = weights[k]
        add_edge!(g, u, v)
        u != v && add_edge!(g, v, u)
        push!(adj[u], (v, w))
        u != v && push!(adj[v], (u, w))
    end

    return RoutingGraph(n_nodes, adj, node_labels, g)
end

function _routing_distmx(graph::RoutingGraph)::Matrix{Float64}
    n = graph.n_nodes
    distmx = fill(Inf, n, n)
    for i in 1:n
        distmx[i, i] = 0.0
        for (v, w) in graph.adj[i]
            distmx[i, v] = w
        end
    end
    return distmx
end

function route(::DijkstraRouting, input::RoutingInput)::RoutingOutput
    g = input.graph.g
    src = input.source
    dst = input.destination
    distmx = _routing_distmx(input.graph)

    state = Graphs.dijkstra_shortest_paths(g, src, distmx)
    if isfinite(state.dists[dst]) && state.dists[dst] < Inf
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

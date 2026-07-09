using Graphs
using SatelliteSimNet
using Test

function make_routing_graph(
    n_nodes::Int,
    edges::Vector{Tuple{Int,Int}},
    weights::Vector{Float64},
)::RoutingGraph
    adj = Dict{Int,Vector{Tuple{Int,Float64}}}()
    g = SimpleDiGraph(n_nodes)
    for (index, (source, destination)) in pairs(edges)
        add_edge!(g, source, destination)
        push!(get!(adj, source, Tuple{Int,Float64}[]), (destination, weights[index]))
    end
    return RoutingGraph(n_nodes, adj, string.(1:n_nodes), g)
end

@testset "RoutingGraph weighted directed semantics" begin
    weighted_graph = make_routing_graph(
        3,
        Tuple{Int,Int}[(1, 2), (2, 3), (1, 3)],
        [1.0, 2.0, 10.0],
    )

    dijkstra = route(DijkstraRouting(), RoutingInput(weighted_graph, 1, 3))
    @test dijkstra.path == [1, 2, 3]
    @test isapprox(dijkstra.total_weight, 3.0; atol = 1e-12)

    ecmp = route(ECMPRouting(), RoutingInput(weighted_graph, 1, 3))
    @test ecmp.path == [1, 2, 3]
    @test isapprox(ecmp.total_weight, 3.0; atol = 1e-12)

    min_load = route(MinLoadRouting(), RoutingInput(weighted_graph, 1, 3))
    @test min_load.path == [1, 2, 3]
    @test isapprox(min_load.total_weight, 3.0; atol = 1e-12)

    directed_graph = make_routing_graph(
        3,
        Tuple{Int,Int}[(1, 2), (2, 3)],
        [1.0, 1.0],
    )

    reverse_dijkstra = route(DijkstraRouting(), RoutingInput(directed_graph, 3, 1))
    @test isempty(reverse_dijkstra.path)
    @test reverse_dijkstra.total_weight == Inf

    reverse_ecmp = route(ECMPRouting(), RoutingInput(directed_graph, 3, 1))
    @test isempty(reverse_ecmp.path)
    @test reverse_ecmp.total_weight == Inf

    reverse_min_load = route(MinLoadRouting(), RoutingInput(directed_graph, 3, 1))
    @test isempty(reverse_min_load.path)
    @test reverse_min_load.total_weight == Inf

    @test isempty(ecmp_paths(3, Tuple{Int,Int}[(1, 2), (2, 3)], [1.0, 1.0], 3, 1))
    @test isempty(min_load_path(3, Tuple{Int,Int}[(1, 2), (2, 3)], [1.0, 1.0], 3, 1, [0.0, 0.0], [1.0, 1.0]))
end

@testset "ECMP helper keeps equivalent shortest paths" begin
    edges = Tuple{Int,Int}[(1, 2), (2, 4), (1, 3), (3, 4), (1, 4)]
    weights = [1.0, 1.0, 1.0, 1.0, 3.0]

    paths = ecmp_paths(4, edges, weights, 1, 4; K = 10)
    @test length(paths) == 2
    @test [1, 2, 4] in paths
    @test [1, 3, 4] in paths
    @test !([1, 4] in paths)
end

# ===== RoutingGraph builder 与 routing_algorithm 执行 (C3/H3) =====

using Test
using SatelliteSimNet: build_routing_graph, DijkstraRouting, ECMPRouting,
    MinLoadRouting, route, RoutingInput, RoutingOutput
import SatelliteSimNet

@testset "RoutingGraph builder" begin
    edges = [(1, 2), (2, 3), (1, 3)]
    weights = [10.0, 5.0, 20.0]
    graph = build_routing_graph(3, edges, weights)

    @test graph.n_nodes == 3
    @test haskey(graph.adj, 1)
    @test length(graph.adj[2]) >= 2

    result = route(DijkstraRouting(), RoutingInput(graph, 1, 3))
    @test result.path == [1, 2, 3]
    @test result.total_weight ≈ 15.0
    @test result.algorithm == "Dijkstra"

    unreachable_graph = build_routing_graph(4, [(1, 2)], [1.0])
    unreachable = route(DijkstraRouting(), RoutingInput(unreachable_graph, 1, 4))
    @test isempty(unreachable.path)
    @test unreachable.total_weight == Inf

    @test_throws ArgumentError build_routing_graph(3, [(1, 2)], [1.0, 2.0])
    @test_throws ArgumentError build_routing_graph(3, [(1, 4)], [1.0])
end

@testset "routing_algorithm 差异" begin
    # 菱形：1-2-4 与 1-3-4 等长
    edges = [(1, 2), (2, 4), (1, 3), (3, 4)]
    weights = [1.0, 1.0, 1.0, 1.0]
    graph = build_routing_graph(4, edges, weights)

    d = route(DijkstraRouting(), RoutingInput(graph, 1, 4))
    e = route(ECMPRouting(), RoutingInput(graph, 1, 4))
    SatelliteSimNet._MINLOAD_STATIC_FALLBACK_WARNED[] = false
    m = route(MinLoadRouting(), RoutingInput(graph, 1, 4))
    @test SatelliteSimNet._MINLOAD_STATIC_FALLBACK_WARNED[]

    @test d.total_weight ≈ 2.0
    @test e.total_weight ≈ 2.0
    @test m.total_weight ≈ 2.0
    @test !isempty(d.path) && !isempty(e.path) && !isempty(m.path)
    @test d.algorithm == "Dijkstra"
    @test startswith(e.algorithm, "ECMP")
    @test m.algorithm == "MinLoad"
end

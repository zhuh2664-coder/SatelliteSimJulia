# ===== PINNRouting Dijkstra fallback (H4) =====

using Test
using SatelliteSimNet: PINNRoutingAlgorithm, build_routing_graph, route, RoutingInput

@testset "PINNRouting fallback" begin
    edges = [(1, 2), (2, 3)]
    weights = [2.0, 3.0]
    graph = build_routing_graph(3, edges, weights)

    mock_predict(pinn, adj, src, dst) = 42.0
    alg = PINNRoutingAlgorithm(nothing, mock_predict)

    result = route(alg, RoutingInput(graph, 1, 3))
    @test result.path == [1, 2, 3]
    @test result.total_weight ≈ 42.0
    @test result.algorithm == "PINNRouting"
    @test !isempty(result.path)

    same = route(alg, RoutingInput(graph, 2, 2))
    @test same.path == [2]
    @test same.total_weight == 0.0

    disconnected = build_routing_graph(4, [(1, 2)], [1.0])
    unreachable = route(alg, RoutingInput(disconnected, 1, 4))
    @test isempty(unreachable.path)
    @test unreachable.total_weight == Inf
    @test unreachable.algorithm == "PINNRouting-unreachable"
end

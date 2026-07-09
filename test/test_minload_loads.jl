# ===== MinLoadRouting 无负载/有负载两种情形 =====

using Test
using SatelliteSimNet: MinLoadRouting, DijkstraRouting, build_routing_graph,
    route, RoutingInput, _MINLOAD_STATIC_FALLBACK_WARNED, _extract_graph_edges
import SatelliteSimNet

@testset "MinLoadRouting load-aware" begin
    edges = [(1, 2), (2, 4), (1, 3), (3, 4)]
    weights = [1.0, 1.0, 2.0, 2.0]
    graph = build_routing_graph(4, edges, weights)

    SatelliteSimNet._MINLOAD_STATIC_FALLBACK_WARNED[] = false
    static = route(MinLoadRouting(), RoutingInput(graph, 1, 4))
    dijkstra = route(DijkstraRouting(), RoutingInput(graph, 1, 4))
    @test static.path == dijkstra.path
    @test static.path == [1, 2, 4]
    @test static.algorithm == "MinLoad"
    @test SatelliteSimNet._MINLOAD_STATIC_FALLBACK_WARNED[]

    extracted_edges, _ = _extract_graph_edges(graph)
    congested_idx = findfirst(e -> e == (2, 4), extracted_edges)
    @test congested_idx !== nothing
    loads = zeros(length(extracted_edges))
    caps = fill(100.0, length(extracted_edges))
    loads[congested_idx] = 500.0

    loaded = route(MinLoadRouting(), RoutingInput(
        graph, 1, 4; current_loads=loads, capacities=caps,
    ))
    @test loaded.algorithm == "MinLoad-congestion"
    @test loaded.path == [1, 3, 4]
    @test loaded.path != static.path
    @test loaded.total_weight > static.total_weight
end

#!/usr/bin/env julia

using Graphs
using Test
using SatelliteSimNet

function make_routing_graph(n_nodes, edges, weights)
    adj = Dict{Int,Vector{Tuple{Int,Float64}}}()
    graph = SimpleDiGraph(n_nodes)

    for (idx, (src, dst)) in enumerate(edges)
        add_edge!(graph, src, dst)
        push!(get!(adj, src, Tuple{Int,Float64}[]), (dst, weights[idx]))
    end

    return RoutingGraph(n_nodes, adj, [string(i) for i in 1:n_nodes], graph)
end

@testset "Routing algorithm matrix" begin
    edges = [(1, 2), (2, 4), (1, 3), (3, 4), (1, 4)]
    weights = [1.0, 1.0, 1.0, 1.0, 10.0]
    routing_graph = make_routing_graph(4, edges, weights)
    input = RoutingInput(routing_graph, 1, 4)
    shortest_paths = [[1, 2, 4], [1, 3, 4]]

    @testset "Dijkstra route contract" begin
        out = route(DijkstraRouting(), input)

        @test out.path in shortest_paths
        @test isapprox(out.total_weight, 2.0; atol=1e-9)
        @test out.algorithm == "Dijkstra"

        unreachable = route(DijkstraRouting(), RoutingInput(routing_graph, 4, 1))
        @test isempty(unreachable.path)
        @test unreachable.total_weight == Inf
    end

    @testset "ECMP route and candidate contract" begin
        out = route(ECMPRouting(), input)
        paths = ecmp_paths(4, edges, weights, 1, 4; K=10)

        @test out.path in shortest_paths
        @test isapprox(out.total_weight, 2.0; atol=1e-9)
        @test out.algorithm == "ECMP"
        @test sort(paths) == sort(shortest_paths)
    end

    @testset "MinLoad route and load-aware helper contract" begin
        out = route(MinLoadRouting(), input)
        loads = [100.0, 100.0, 0.0, 0.0, 0.0]
        capacities = fill(100.0, length(edges))
        load_aware_path = min_load_path(4, edges, weights, 1, 4, loads, capacities; K=5)

        @test out.path in shortest_paths
        @test isapprox(out.total_weight, 2.0; atol=1e-9)
        @test out.algorithm == "MinLoad"
        @test load_aware_path == [1, 3, 4]
    end

    @testset "PINN fake predictor contract" begin
        fake_predict(_pinn, adj, src, dst) = adj[src, dst] == Inf ? 42.0 : adj[src, dst]

        alg = PINNRoutingAlgorithm(nothing, fake_predict; sats_per_plane=2, n_planes=2)
        out = route(alg, input)
        adj = routing_graph_to_adjacency_matrix(routing_graph)
        all_pairs = pinn_predict_all_pairs(alg, adj)

        @test out.path == Int[]
        @test out.total_weight == 10.0
        @test out.algorithm == "PINNRouting"
        @test size(all_pairs) == (4, 4)
        @test all(all_pairs[i, i] == 0.0 for i in 1:4)
        @test all_pairs[1, 4] == 10.0
        @test all_pairs[4, 1] == 42.0
    end
end

println("ROUTING ALGORITHM MATRIX: ALL PASS")

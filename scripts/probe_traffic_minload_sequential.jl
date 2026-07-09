#!/usr/bin/env julia

using Graphs
using Test
using SatelliteSimNet
using SatelliteSimTraffic

function make_bidirectional_routing_graph(n_nodes::Int, edges, weights)
    adj = Dict{Int,Vector{Tuple{Int,Float64}}}()
    graph = SimpleDiGraph(n_nodes)

    for (idx, (src, dst)) in enumerate(edges)
        weight = weights[idx]
        add_edge!(graph, src, dst)
        add_edge!(graph, dst, src)
        push!(get!(adj, src, Tuple{Int,Float64}[]), (dst, weight))
        push!(get!(adj, dst, Tuple{Int,Float64}[]), (src, weight))
    end

    return RoutingGraph(n_nodes, adj, string.(1:n_nodes), graph)
end

function add_path_load!(loads, edges, path, rate_mbps)
    for i in 1:length(path)-1
        edge_idx = findfirst(
            j -> edges[j] == (path[i], path[i+1]) || edges[j] == (path[i+1], path[i]),
            eachindex(edges),
        )
        edge_idx === nothing && error("missing edge for path hop $(path[i]) -> $(path[i+1])")
        loads[edge_idx] += rate_mbps
    end
    return loads
end

@testset "Traffic demands drive sequential MinLoad routing" begin
    edges = [(1, 2), (2, 4), (1, 3), (3, 4)]
    weights = fill(1.0, length(edges))
    capacities = fill(100.0, length(edges))
    loads = zeros(Float64, length(edges))

    graph = make_bidirectional_routing_graph(4, edges, weights)
    fallback = route(MinLoadRouting(), RoutingInput(graph, 1, 4))

    @test fallback.path in ([1, 2, 4], [1, 3, 4])
    @test fallback.total_weight ≈ 2.0
    @test fallback.algorithm == "MinLoad"

    demands = [
        TrafficDemand(
            id=1,
            source_ground_id=1,
            destination_ground_id=4,
            start_elapsed_s=0,
            end_elapsed_s=60,
            rate_mbps=100.0,
        ),
        TrafficDemand(
            id=2,
            source_ground_id=1,
            destination_ground_id=4,
            start_elapsed_s=0,
            end_elapsed_s=60,
            rate_mbps=100.0,
        ),
    ]

    selected_paths = Vector{Int}[]
    for demand in demands
        path = min_load_path(
            4,
            edges,
            weights,
            demand.source_ground_id,
            demand.destination_ground_id,
            loads,
            capacities;
            K=4,
        )
        @test path in ([1, 2, 4], [1, 3, 4])
        push!(selected_paths, path)
        add_path_load!(loads, edges, path, demand.rate_mbps)
    end

    @test selected_paths[1] != selected_paths[2]
    @test sort(selected_paths) == sort([[1, 2, 4], [1, 3, 4]])
    @test loads == fill(100.0, length(edges))
end

println("TRAFFIC MINLOAD SEQUENTIAL: ALL PASS")

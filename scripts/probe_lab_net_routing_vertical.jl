#!/usr/bin/env julia

using Graphs
using InteractiveUtils
using Test
using SatelliteSimCore
using SatelliteSimLab
using SatelliteSimNet

function routing_graph_from_available_isls(n_nodes::Int, links::Vector{Tuple{Int,Int}}, weights::Vector{Float64})
    adj = Dict{Int,Vector{Tuple{Int,Float64}}}()
    graph = SimpleDiGraph(n_nodes)

    for (idx, (src, dst)) in enumerate(links)
        weight = weights[idx]
        add_edge!(graph, src, dst)
        add_edge!(graph, dst, src)
        push!(get!(adj, src, Tuple{Int,Float64}[]), (dst, weight))
        push!(get!(adj, dst, Tuple{Int,Float64}[]), (src, weight))
    end

    return RoutingGraph(n_nodes, adj, string.(1:n_nodes), graph)
end

function route_method_file(alg, input)
    method = @which route(alg, input)
    return String(method.file)
end

@testset "Lab-Net-Routing vertical route dispatch probe" begin
    n_sat = 24
    n_planes = 6
    constraints = PhysicalConstraints(
        isl_max_range_km=12_000.0,
        isl_require_los=false,
        gsl_min_elevation_deg=5.0,
        gsl_max_range_km=20_000.0,
    )
    config = ExperimentConfig(
        constellation_params=Dict{Symbol,Float64}(
            :T => Float64(n_sat),
            :P => Float64(n_planes),
            :F => 1.0,
            :alt_km => 550.0,
            :inc_deg => 53.0,
        ),
        tspan=[0.0, 60.0],
        topology_strategy=GridPlusStrategy(),
        routing_algorithm=DijkstraRouting(),
        constraints=constraints,
        random_seed=7,
    )

    _, positions = propagate_constellation_positions(config)
    topology = generate_topology(GridPlusStrategy(), n_sat, n_planes)
    all_links = vcat(topology.static_links, topology.dynamic_candidates)
    isl_results = evaluate_isl_batch(positions[:, end, :], all_links; constraints=constraints)

    available = Tuple{Int,Int}[
        (Int(all_links[i][1]), Int(all_links[i][2]))
        for (i, result) in enumerate(isl_results) if result.available
    ]
    weights = Float64[result.latency_ms for result in isl_results if result.available]

    @test !isempty(available)
    @test length(available) == length(weights)

    graph = routing_graph_from_available_isls(n_sat, available, weights)
    pairs = [(1, 7), (2, 14), (6, 18)]

    algs = [
        :dijkstra => DijkstraRouting(),
        :ecmp => ECMPRouting(),
        :min_load => MinLoadRouting(),
    ]
    outputs = Dict{Symbol,Vector{RoutingOutput}}()

    for (name, alg) in algs
        sample_input = RoutingInput(graph, pairs[1][1], pairs[1][2])
        dispatch_file = route_method_file(alg, sample_input)

        if name == :dijkstra
            @test endswith(dispatch_file, "dijkstra.jl")
        else
            @test endswith(dispatch_file, "advanced_routing.jl")
        end

        outputs[name] = [
            route(alg, RoutingInput(graph, src, dst))
            for (src, dst) in pairs
        ]

        @test all(out -> !isempty(out.path), outputs[name])
        @test all(out -> isfinite(out.total_weight), outputs[name])
        @test all(out -> out.algorithm == (
            name == :dijkstra ? "Dijkstra" :
            name == :ecmp ? "ECMP" : "MinLoad"
        ), outputs[name])
    end

    @test length(outputs[:dijkstra]) == length(pairs)
    @test [out.total_weight for out in outputs[:min_load]] == [out.total_weight for out in outputs[:dijkstra]]
end

println("LAB NET ROUTING VERTICAL: ALL PASS")

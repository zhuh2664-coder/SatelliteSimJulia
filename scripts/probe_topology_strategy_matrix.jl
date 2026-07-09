#!/usr/bin/env julia

# Probe multiple topology strategies through the physical Link -> Net -> Metrics
# chain. This complements unit tests that only check topology generation.

using Printf
using Test

using SatelliteSimCore
using SatelliteSimNet

const T = parse(Int, get(ENV, "SATSIM_TOPO_MATRIX_T", "66"))
const P = parse(Int, get(ENV, "SATSIM_TOPO_MATRIX_P", "6"))
const F = parse(Int, get(ENV, "SATSIM_TOPO_MATRIX_F", "1"))
const ALT_KM = parse(Float64, get(ENV, "SATSIM_TOPO_MATRIX_ALT_KM", "780.0"))
const INC_DEG = parse(Float64, get(ENV, "SATSIM_TOPO_MATRIX_INC_DEG", "86.4"))
const TSPAN = [0.0, 60.0, 120.0]

function all_links(output)
    return unique(vcat(output.static_links, output.dynamic_candidates))
end

function available_edges_and_weights(positions_last::Matrix{Float64}, links, constraints)
    results = evaluate_isl_batch(positions_last, links; constraints)
    edges = Tuple{Int,Int}[]
    weights = Float64[]
    for (idx, result) in enumerate(results)
        if result.available
            push!(edges, (Int(links[idx][1]), Int(links[idx][2])))
            push!(weights, result.latency_ms)
        end
    end
    return edges, weights, results
end

function summarize_strategy(name::String, strategy, positions, constraints)
    output = generate_topology(strategy, T, P)
    links = all_links(output)
    positions_last = Matrix(positions[:, end, :])
    edges, weights, isl_results = available_edges_and_weights(positions_last, links, constraints)

    D = if isempty(edges)
        dist = fill(Inf, T, T)
        for i in 1:T
            dist[i, i] = 0.0
        end
        dist
    else
        all_pairs_shortest_paths(build_adjacency(T, edges, weights))
    end

    network = compute_network_metrics(D)
    finite_pairs = count(isfinite, D)
    @test size(D) == (T, T)
    @test all(isfinite(D[i, i]) && D[i, i] == 0.0 for i in 1:T)
    @test length(links) == length(isl_results)

    return (
        name = name,
        description = output.description,
        static = length(output.static_links),
        dynamic = length(output.dynamic_candidates),
        candidates = length(links),
        available = length(edges),
        finite_pairs = finite_pairs,
        connectivity = network.connectivity_ratio,
        diameter = network.diameter,
        avg_path_length = network.avg_path_length,
    )
end

function main()
    println("SatelliteSimJulia topology strategy matrix probe")
    @printf("constellation: T=%d P=%d F=%d alt=%.1fkm inc=%.1fdeg steps=%d\n",
        T, P, F, ALT_KM, INC_DEG, length(TSPAN))

    elems = generate_walker_delta(T = T, P = P, F = F, alt_km = ALT_KM, inc_deg = INC_DEG)
    positions = propagate_to_ecef(elems, TSPAN; propagator = J2Propagator())
    constraints = LEO_DEFAULTS

    strategies = Pair{String,Any}[
        "GridPlus" => GridPlusStrategy(),
        "TShape" => TShapeStrategy(),
        "Spiral" => SpiralStrategy(),
        "Honeycomb" => HoneycombStrategy(),
        "Ring" => RingStrategy(),
        "Mesh" => MeshStrategy(),
        "NearestNeighbor(k=4,t=last)" => NearestNeighborStrategy(positions = positions, k = 4, time_step = size(positions, 2)),
    ]

    rows = NamedTuple[]
    failures = String[]
    for (name, strategy) in strategies
        try
            row = summarize_strategy(name, strategy, positions, constraints)
            push!(rows, row)
            @printf("[PASS] %-24s cand=%4d avail=%4d finite=%5d conn=%.3f avg_ms=%.3f\n",
                row.name, row.candidates, row.available, row.finite_pairs,
                row.connectivity, row.avg_path_length)
        catch err
            msg = "$name => $(typeof(err)): $(sprint(showerror, err))"
            push!(failures, msg)
            println("[FAIL] $msg")
        end
    end

    println()
    println("summary:")
    @printf("%-24s %8s %8s %8s %8s %10s %10s\n",
        "strategy", "static", "dynamic", "cand", "avail", "conn", "avg_path")
    for row in rows
        @printf("%-24s %8d %8d %8d %8d %10.3f %10.3f\n",
            row.name, row.static, row.dynamic, row.candidates, row.available,
            row.connectivity, row.avg_path_length)
    end

    if !isempty(failures)
        println()
        println("failures:")
        foreach(f -> println("  - $f"), failures)
        exit(1)
    end

    println()
    println("TOPOLOGY MATRIX: ALL PASS")
end

main()

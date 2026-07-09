#!/usr/bin/env julia

using Test
using JSON
using CairoMakie
using SatelliteSimCore
using SatelliteSimNet
using SatelliteSimTraffic
using SatelliteSimLab

function load_records(frames)
    records = Dict{String,Any}[]
    for frame in frames
        for load in frame.link_loads
            push!(records, Dict{String,Any}(
                "time_index" => load.time_index,
                "elapsed_s" => load.elapsed_s,
                "link_type" => string(load.link_type),
                "link_id" => load.link_id,
                "endpoint_a_id" => load.endpoint_a_id,
                "endpoint_b_id" => load.endpoint_b_id,
                "load_mbps" => load.load_mbps,
                "capacity_mbps" => load.capacity_mbps,
            ))
        end
    end
    return records
end

function save_load_plot(path::AbstractString, records)
    figure = Figure(size = (760, 420))
    axis = Axis(
        figure[1, 1],
        title = "Temporal Traffic Load",
        xlabel = "elapsed_s",
        ylabel = "load_mbps",
    )

    groups = Dict{Tuple{Int,Int},Vector{Dict{String,Any}}}()
    for record in records
        key = (record["endpoint_a_id"], record["endpoint_b_id"])
        push!(get!(groups, key, Dict{String,Any}[]), record)
    end

    palette = [:dodgerblue, :orange, :seagreen, :crimson, :purple]
    for (idx, (edge, group)) in enumerate(sort(collect(groups); by = first))
        ordered = sort(group; by = record -> record["elapsed_s"])
        lines!(
            axis,
            [record["elapsed_s"] for record in ordered],
            [record["load_mbps"] for record in ordered];
            color = palette[mod1(idx, length(palette))],
            linewidth = 3,
            label = "$(edge[1])-$(edge[2])",
        )
        scatter!(
            axis,
            [record["elapsed_s"] for record in ordered],
            [record["load_mbps"] for record in ordered];
            color = palette[mod1(idx, length(palette))],
        )
    end
    axislegend(axis; position = :rt)
    save(path, figure)
    return path
end

@testset "Viz traffic load artifacts" begin
    n_sat = 4
    n_planes = 1
    positions = zeros(Float64, n_sat, 2, 3)

    positions[1, 1, :] .= (7000.0, 0.0, 0.0)
    positions[2, 1, :] .= (7001.0, 0.0, 0.0)
    positions[4, 1, :] .= (7002.0, 0.0, 0.0)
    positions[3, 1, :] .= (7100.0, 0.0, 0.0)

    positions[1, 2, :] .= (7000.0, 0.0, 0.0)
    positions[3, 2, :] .= (7001.0, 0.0, 0.0)
    positions[4, 2, :] .= (7002.0, 0.0, 0.0)
    positions[2, 2, :] .= (7100.0, 0.0, 0.0)

    constraints = PhysicalConstraints(
        isl_max_range_km=1_000.0,
        isl_require_los=false,
        isl_max_capacity_mbps=100.0,
    )
    demand = TrafficDemand(
        id=1,
        source_ground_id=1,
        destination_ground_id=4,
        start_elapsed_s=0,
        end_elapsed_s=120,
        rate_mbps=50.0,
    )

    frames = assess_temporal_flow_routes(
        positions,
        n_sat,
        n_planes,
        t -> NearestNeighborStrategy(positions=positions, k=1, time_step=t),
        constraints,
        [demand],
        DijkstraRouting();
        elapsed_by_time = [0, 60],
    )

    records = load_records(frames)
    @test length(records) == 4
    @test sort([(r["time_index"], r["endpoint_a_id"], r["endpoint_b_id"]) for r in records]) ==
          [(1, 1, 2), (1, 2, 4), (2, 1, 3), (2, 3, 4)]
    @test all(record -> record["load_mbps"] == 50.0, records)
    @test all(record -> record["capacity_mbps"] == 100.0, records)

    outdir = mktempdir()
    json_path = joinpath(outdir, "traffic_loads.json")
    open(json_path, "w") do io
        JSON.print(io, Dict("records" => records), 2)
    end
    png_path = save_load_plot(joinpath(outdir, "traffic_loads.png"), records)

    parsed = JSON.parsefile(json_path)
    @test length(parsed["records"]) == 4
    @test isfile(png_path)
    @test filesize(json_path) > 500
    @test filesize(png_path) > 1000
end

println("VIZ TRAFFIC LOAD ARTIFACT: ALL PASS")

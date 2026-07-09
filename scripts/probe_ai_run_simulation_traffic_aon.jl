#!/usr/bin/env julia

using JSON
using Test
using SatelliteSimCore
using SatelliteSimLab
using SatelliteSimNet

function subpoint_deg(positions::Array{Float64,3}, sat_id::Int)
    x, y, z = positions[sat_id, 1, 1], positions[sat_id, 1, 2], positions[sat_id, 1, 3]
    radius = sqrt(x * x + y * y + z * z)
    return (asind(z / radius), atan(y, x) * 180 / pi)
end

@testset "AI run_simulation traffic AON bridge" begin
    SatelliteSimLab.ensure_default_ai_tools!()
    schema = SatelliteSimLab.get_ai_tool("run_simulation").input_schema
    properties = schema["properties"]
    @test haskey(properties, "traffic")
    @test haskey(properties, "ground_stations")
    @test haskey(properties, "ground_pairs")

    # Build stable ground points from the same Walker geometry used by the tool.
    seed = ExperimentConfig(
        constellation_params = Dict(:T => 48.0, :P => 8.0, :F => 1.0, :alt_km => 550.0, :inc_deg => 53.0),
        tspan = collect(range(0.0, 120.0; length = 3)),
        topology_strategy = GridPlusStrategy(),
    )
    _, positions = propagate_constellation_positions(seed)
    src_lat, src_lon = subpoint_deg(positions, 1)
    dst_lat, dst_lon = subpoint_deg(positions, 2)

    raw = SatelliteSimLab.execute_tool(
        "run_simulation",
        Dict{String,Any}(
            "constellation" => "walker 48/8/1",
            "duration_s" => 120,
            "steps" => 3,
            "topology" => "balanced",
            "propagator" => "fast",
            "traffic" => "uniform",
            "ground_stations" => [
                Dict{String,Any}("id" => 1, "name" => "source", "lat" => src_lat, "lon" => src_lon, "alt_km" => 0.0),
                Dict{String,Any}("id" => 2, "name" => "destination", "lat" => dst_lat, "lon" => dst_lon, "alt_km" => 0.0),
            ],
            "ground_pairs" => [[1, 2]],
        ),
    )
    data = JSON.parse(raw; allownan = true)

    @test data["traffic_enabled"] == true
    @test data["traffic_demands"] == 1
    @test data["ground_stations"] == 2
    @test data["ground_pairs"] == 1
    @test data["traffic_evaluation_ran"] == true
    @test data["traffic_fallback"] == false
    @test data["traffic_time_steps"] == 3
    @test data["traffic_assignments"] == 2
    @test data["offered_mbps"] == 100.0
    @test data["carried_mbps"] + data["dropped_mbps"] == data["offered_mbps"]

    default_raw = SatelliteSimLab.execute_tool(
        "run_simulation",
        Dict{String,Any}(
            "constellation" => "walker 6/3/1",
            "duration_s" => 60,
            "steps" => 2,
            "topology" => "minimal",
            "propagator" => "fast",
        ),
    )
    default_data = JSON.parse(default_raw; allownan = true)
    @test default_data["traffic_enabled"] == false
    @test default_data["traffic_demands"] == 0
    @test default_data["traffic_evaluation_ran"] == false
end

println("AI RUN SIMULATION TRAFFIC AON: ALL PASS")

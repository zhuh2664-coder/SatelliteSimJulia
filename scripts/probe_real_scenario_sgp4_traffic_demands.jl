#!/usr/bin/env julia

using JSON
using SatelliteSimLab
using Test

const ROOT = normpath(joinpath(@__DIR__, ".."))
const STARLINK_TLE = joinpath(ROOT, "data", "real_sources", "celestrak", "starlink.tle")
const ENDPOINTS_JSON = joinpath(ROOT, "data", "real_sources", "derived", "ground_endpoints.json")
const DEMANDS_JSON = joinpath(ROOT, "data", "real_sources", "derived", "traffic_demands_calibrated.json")

to_int(x) = x isa Integer ? Int(x) : parse(Int, String(x))
to_float(x) = x isa Real ? Float64(x) : parse(Float64, String(x))

function _station_arg(row)
    return Dict{String,Any}(
        "id" => to_int(row["id"]),
        "name" => String(row["label"]),
        "lat" => to_float(row["lat"]),
        "lon" => to_float(row["lon"]),
        "alt_km" => to_float(row["alt_km"]),
    )
end

function _demand_arg(row)
    return Dict{String,Any}(
        "id" => to_int(row["id"]),
        "source_ground_id" => to_int(row["source_ground_id"]),
        "destination_ground_id" => to_int(row["destination_ground_id"]),
        "start_elapsed_s" => 0,
        "end_elapsed_s" => 600,
        "rate_mbps" => min(to_float(row["rate_mbps"]), 50.0),
    )
end

@testset "Real scenario SGP4 with derived traffic demands" begin
    @test isfile(STARLINK_TLE)
    @test isfile(ENDPOINTS_JSON)
    @test isfile(DEMANDS_JSON)

    endpoints = JSON.parsefile(ENDPOINTS_JSON)
    demands_all = JSON.parsefile(DEMANDS_JSON)
    selected_demands = demands_all[1:min(8, length(demands_all))]
    max_ground_id = maximum(max(to_int(d["source_ground_id"]), to_int(d["destination_ground_id"])) for d in selected_demands)
    selected_endpoints = endpoints[1:max_ground_id]

    result = JSON.parse(SatelliteSimLab.execute_tool(
        "run_simulation",
        Dict{String,Any}(
            "constellation" => "starlink",
            "propagator" => "tle_based",
            "tle" => STARLINK_TLE,
            "max_sats" => 8,
            "topology" => "balanced",
            "duration_s" => 600,
            "steps" => 3,
            "ground_stations" => Any[_station_arg(row) for row in selected_endpoints],
            "traffic_demands" => Any[_demand_arg(row) for row in selected_demands],
        ),
    ))

    @test result["propagator"] == "tle_based"
    @test result["n_satellites"] == 8
    @test result["traffic_enabled"] == true
    @test result["traffic_demands"] == length(selected_demands)
    @test result["ground_stations"] == length(selected_endpoints)
    @test result["traffic_evaluation_ran"] == true
    @test result["traffic_fallback"] == false
    @test result["traffic_time_steps"] == 3
    @test result["traffic_assignments"] >= length(selected_demands)
    @test result["offered_mbps"] > 0
    @test haskey(result, "carried_mbps")
    @test haskey(result, "dropped_mbps")
end

println("REAL SCENARIO SGP4 TRAFFIC DEMANDS: ALL PASS")

#!/usr/bin/env julia

using JSON
using SatelliteSimLab
using Test

const SGP4_TRAFFIC_TLE = """
STARLINK-1008
1 44714U 19074B   26159.15246276  .00058859  00000+0  10712-2 0  9994
2 44714  53.1504 111.9517 0002807  92.7458 267.3873 15.48963375362814
STARLINK-1012
1 44718U 19074F   26159.27942812  .00049564  00000+0  89602-3 0  9998
2 44718  53.1557 111.6305 0002485  92.2627 267.8667 15.49229421362828
STARLINK-1017
1 44723U 19074L   26159.13602000  .00033057  00000+0  10826-2 0  9992
2 44723  53.0476 111.7034 0005216  40.8758 319.2632 15.31380096362799
STARLINK-1020
1 44725U 19074N   26159.23599243  .00065154  00000+0  97314-3 0  9990
2 44725  53.1570 135.8788 0004387  65.3813 294.7655 15.54445420362466
STARLINK-1036
1 44741U 19074AE  26159.10913754  .00061564  00000+0  51954-3 0  9992
2 44741  53.0416 105.5573 0002927  15.0481 345.0622 15.69218654362871
STARLINK-1039
1 44744U 19074AH  26159.23158254  .00035615  00000+0  12701-2 0  9999
2 44744  53.0574 156.6563 0004119  40.7934 319.3373 15.28581362362172
"""

@testset "AI run_simulation SGP4 traffic AON bridge" begin
    result = JSON.parse(SatelliteSimLab.execute_tool(
        "run_simulation",
        Dict{String,Any}(
            "constellation" => "starlink",
            "propagator" => "tle_based",
            "tle" => SGP4_TRAFFIC_TLE,
            "max_sats" => 6,
            "topology" => "balanced",
            "traffic" => "uniform",
            "duration_s" => 120,
            "steps" => 3,
            "ground_stations" => Any[
                Dict("id" => 1, "name" => "source", "lat" => 0.0, "lon" => 116.4, "alt_km" => 0.0),
                Dict("id" => 2, "name" => "destination", "lat" => 40.0, "lon" => 160.0, "alt_km" => 0.0),
            ],
            "ground_pairs" => Any[Any[1, 2]],
        ),
    ))

    @test result["propagator"] == "tle_based"
    @test result["constellation"] == "starlink"
    @test result["n_satellites"] == 6
    @test result["tle_source"] == 6
    @test result["traffic_enabled"] == true
    @test result["traffic_demands"] == 1
    @test result["ground_stations"] == 2
    @test result["ground_pairs"] == 1
    @test result["traffic_evaluation_ran"] == true
    @test result["traffic_fallback"] == false
    @test result["traffic_time_steps"] == 3
    @test result["traffic_assignments"] > 0
    @test result["offered_mbps"] > 0.0
    @test haskey(result, "carried_mbps")
    @test haskey(result, "dropped_mbps")
end

println("AI RUN SIMULATION SGP4 TRAFFIC AON: ALL PASS")

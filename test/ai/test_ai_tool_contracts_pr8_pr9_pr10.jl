using Test
using JSON
using SatelliteSimCore
using SatelliteSimLab
using SatelliteSimNet

const STARLINK_TLE_CONTRACT = """
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

function _ai_contract_subpoint_deg(positions::Array{Float64,3}, sat_id::Int)
    x, y, z = positions[sat_id, 1, 1], positions[sat_id, 1, 2], positions[sat_id, 1, 3]
    radius = sqrt(x * x + y * y + z * z)
    return (asind(z / radius), atan(y, x) * 180 / pi)
end

@testset "AI tool contracts for traffic/routing/orbit" begin
    SatelliteSimLab.ensure_default_ai_tools!()

    @testset "schema and list_available expose PR contracts" begin
        run_spec = SatelliteSimLab.get_ai_tool("run_simulation")
        @test run_spec !== nothing
        properties = run_spec.input_schema["properties"]
        for key in ("traffic", "traffic_demands", "ground_stations", "ground_pairs", "routing", "tle", "max_sats")
            @test haskey(properties, key)
        end
        @test properties["routing"]["enum"] == ["shortest_path", "load_balanced", "multipath"]
        @test properties["max_sats"]["type"] == "integer"
        @test properties["tle"]["type"] == "string"

        list_spec = SatelliteSimLab.get_ai_tool("list_available")
        @test list_spec !== nothing
        what_enum = list_spec.input_schema["properties"]["what"]["enum"]
        for key in ("routing", "traffic", "intents")
            @test key in what_enum
        end

        data = JSON.parse(SatelliteSimLab.execute_tool("list_available", Dict{String,Any}("what" => "all")))
        for key in ("topologies", "propagators", "routing", "traffic", "intents")
            @test haskey(data, key)
        end
        @test "tle_based" in data["propagators"]
        @test "load_balanced" in data["routing"]
        @test "uniform" in data["traffic"]
        @test haskey(data["intents"], "routing")
        @test haskey(data["intents"], "traffic")
    end

    @testset "routing and SGP4 schema validation" begin
        good = SatelliteSimLab.validate_tool_args(
            "run_simulation",
            Dict{String,Any}("constellation" => "walker 6/3/1", "routing" => "load_balanced"),
        )
        @test good.ok

        bad_routing = SatelliteSimLab.validate_tool_args(
            "run_simulation",
            Dict{String,Any}("constellation" => "walker 6/3/1", "routing" => "bad_routing"),
        )
        @test !bad_routing.ok
        @test any(occursin("one of", e) for e in bad_routing.errors)

        bad_max_sats = SatelliteSimLab.validate_tool_args(
            "run_simulation",
            Dict{String,Any}("constellation" => "walker 6/3/1", "max_sats" => "6"),
        )
        @test !bad_max_sats.ok
        @test any(occursin("expected type integer", e) for e in bad_max_sats.errors)
    end

    @testset "traffic fallback boundaries" begin
        none_data = JSON.parse(SatelliteSimLab.execute_tool(
            "run_simulation",
            Dict{String,Any}(
                "constellation" => "walker 6/3/1",
                "duration_s" => 60,
                "steps" => 2,
                "topology" => "minimal",
                "propagator" => "fast",
                "traffic" => "none",
            ),
        ); allownan = true)
        @test none_data["traffic_enabled"] == false
        @test none_data["traffic_evaluation_ran"] == false
        @test none_data["traffic_fallback"] == false
        @test none_data["routing"] == "shortest_path"

        fallback_data = JSON.parse(SatelliteSimLab.execute_tool(
            "run_simulation",
            Dict{String,Any}(
                "constellation" => "walker 6/3/1",
                "duration_s" => 60,
                "steps" => 2,
                "topology" => "minimal",
                "propagator" => "fast",
                "traffic" => "uniform",
                "routing" => "load_balanced",
            ),
        ); allownan = true)
        @test fallback_data["traffic_enabled"] == true
        @test fallback_data["traffic_demands"] == 0
        @test fallback_data["traffic_evaluation_ran"] == false
        @test fallback_data["traffic_fallback"] == true
        @test fallback_data["routing"] == "load_balanced"
        @test fallback_data["routing_evaluation_scope"] == "matrix_shortest_path_summary"
    end

    @testset "traffic AON carries routing intent" begin
        seed = SatelliteSimLab.ExperimentConfig(
            constellation_params = Dict(:T => 48.0, :P => 8.0, :F => 1.0, :alt_km => 550.0, :inc_deg => 53.0),
            tspan = collect(range(0.0, 120.0; length = 3)),
            topology_strategy = GridPlusStrategy(),
        )
        _, positions = SatelliteSimLab.propagate_constellation_positions(seed)
        src_lat, src_lon = _ai_contract_subpoint_deg(positions, 1)
        dst_lat, dst_lon = _ai_contract_subpoint_deg(positions, 2)

        data = JSON.parse(SatelliteSimLab.execute_tool(
            "run_simulation",
            Dict{String,Any}(
                "constellation" => "walker 48/8/1",
                "duration_s" => 120,
                "steps" => 3,
                "topology" => "balanced",
                "propagator" => "fast",
                "traffic" => "uniform",
                "routing" => "load_balanced",
                "ground_stations" => [
                    Dict{String,Any}("id" => 1, "name" => "source", "lat" => src_lat, "lon" => src_lon, "alt_km" => 0.0),
                    Dict{String,Any}("id" => 2, "name" => "destination", "lat" => dst_lat, "lon" => dst_lon, "alt_km" => 0.0),
                ],
                "ground_pairs" => [[1, 2]],
            ),
        ); allownan = true)

        @test data["traffic_enabled"] == true
        @test data["traffic_demands"] == 1
        @test data["ground_stations"] == 2
        @test data["ground_pairs"] == 1
        @test data["traffic_evaluation_ran"] == true
        @test data["traffic_fallback"] == false
        @test data["traffic_time_steps"] == 3
        @test data["traffic_assignments"] > 0
        @test data["routing"] == "load_balanced"
        @test data["routing_evaluation_scope"] == "traffic_aon_per_flow"
        @test isapprox(data["carried_mbps"] + data["dropped_mbps"], data["offered_mbps"]; atol = 1e-6)
    end

    @testset "SGP4 TLE contract" begin
        data = JSON.parse(SatelliteSimLab.execute_tool(
            "run_simulation",
            Dict{String,Any}(
                "constellation" => "starlink",
                "propagator" => "tle_based",
                "tle" => STARLINK_TLE_CONTRACT,
                "max_sats" => 6,
                "topology" => "balanced",
                "traffic" => "uniform",
                "routing" => "load_balanced",
                "duration_s" => 120,
                "steps" => 3,
                "ground_stations" => Any[
                    Dict("id" => 1, "name" => "source", "lat" => 0.0, "lon" => 116.4, "alt_km" => 0.0),
                    Dict("id" => 2, "name" => "destination", "lat" => 40.0, "lon" => 160.0, "alt_km" => 0.0),
                ],
                "ground_pairs" => Any[Any[1, 2]],
            ),
        ); allownan = true)

        @test data["propagator"] == "tle_based"
        @test data["constellation"] == "starlink"
        @test data["n_satellites"] == 6
        @test data["tle_source"] == 6
        @test data["routing"] == "load_balanced"
        @test data["traffic_enabled"] == true
        @test data["traffic_demands"] == 1
        @test data["traffic_evaluation_ran"] == true
        @test data["traffic_fallback"] == false
        @test data["traffic_assignments"] > 0
    end
end

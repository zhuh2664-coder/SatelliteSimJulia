using SatelliteSimCore
using SatelliteSimLab
using SatelliteSimNet
using JSON
using Test

function _small_config(; name="lab-smoke")
    return ExperimentConfig(
        name = name,
        constellation_params = Dict(
            :T => 6.0,
            :P => 3.0,
            :F => 1.0,
            :alt_km => 550.0,
            :inc_deg => 53.0,
        ),
        tspan = [0.0, 60.0],
        topology_strategy = GridPlusStrategy(),
        routing_algorithm = DijkstraRouting(),
        users = [
            GroundUser("beijing", 39.9042, 116.4074, 20.0, 100.0, "smoke"),
            GroundUser("singapore", 1.3521, 103.8198, 20.0, 100.0, "smoke"),
        ],
        ground_pairs = [(1, 4), (2, 5), (3, 6)],
    )
end

@testset "SatelliteSimLab" begin
    @testset "run_experiment smoke" begin
        result = run_experiment(_small_config())
        @test result isa ExperimentResult
        @test result.config.name == "lab-smoke"
        @test isfinite(result.latency.avg_latency_ms)
        @test isfinite(result.network.connectivity_ratio)
        @test isfinite(result.fitness)
    end

    @testset "registered AI tools and SGP4 path" begin
        ensure_default_ai_tools!()
        @test "run_simulation" in registered_ai_tools()

        result_json = execute_tool(
            "run_simulation",
            Dict(
                "constellation" => "starlink_tle",
                "topology" => "balanced",
                "propagator" => "tle_based",
                "duration_s" => 60,
                "steps" => 3,
                "max_sats" => 8,
            ),
        )
        result = JSON.parse(result_json)
        @test !haskey(result, "error")
        @test result["propagator"] == "tle_based"
        @test result["n_satellites"] == 8
        @test result["tle_source"] == 8
        @test isfinite(result["avg_latency_ms"])
    end

    @testset "Traffic bridge uses GroundStation positions" begin
        ground_stations = [
            GroundStation(
                id = 1,
                name = "beijing",
                position = GeodeticPosition(39.9042, 116.4074, 0.0),
            ),
            GroundStation(
                id = 2,
                name = "singapore",
                position = GeodeticPosition(1.3521, 103.8198, 0.0),
            ),
        ]
        config = ExperimentConfig(
            name = "traffic-bridge-test",
            constellation_params = Dict(
                :T => 24.0,
                :P => 6.0,
                :F => 1.0,
                :alt_km => 550.0,
                :inc_deg => 53.0,
            ),
            tspan = collect(0.0:60.0:120.0),
            topology_strategy = GridPlusStrategy(),
            routing_algorithm = DijkstraRouting(),
            constraints = PhysicalConstraints(
                isl_max_range_km = 12000.0,
                isl_require_los = false,
                gsl_min_elevation_deg = 5.0,
                gsl_max_range_km = 20000.0,
            ),
            ground_stations = ground_stations,
            users = [
                GroundUser("beijing", 39.9042, 116.4074, 20.0, 100.0, "smoke"),
                GroundUser("singapore", 1.3521, 103.8198, 20.0, 100.0, "smoke"),
            ],
            ground_pairs = [(1, 2)],
        )
        result = run_experiment(config)
        @test length(result.config.traffic_demands) == 1
        @test result.traffic_evaluation !== nothing
        @test length(result.traffic_evaluation.assignments_by_time) == length(config.tspan)
        @test length(result.traffic_evaluation.link_loads_by_time) == length(config.tspan)
    end

    @testset "export and persistence tolerate NaN coverage" begin
        result = run_experiment(_small_config(; name="persist-smoke"))
        as_dict = to_dict(result)
        @test haskey(as_dict, :avg_lat_ms)
        @test to_csv(["persist" => result]) isa String
        @test to_markdown(["persist" => result]) isa String

        record = ExperimentRecord(result.config, result; notes="test")
        path = save_experiment(record)
        loaded = load_experiment(record.id)
        @test isfile(path)
        @test loaded.id == record.id
        @test haskey(loaded.result, "coverage")
    end
end

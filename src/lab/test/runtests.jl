using SatelliteSimCore
using SatelliteSimLab
using SatelliteSimNet
using JSON
using HTTP
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

function _subpoint_deg(positions::Array{Float64,3}, sat_id::Int)
    x, y, z = positions[sat_id, 1, 1], positions[sat_id, 1, 2], positions[sat_id, 1, 3]
    radius = sqrt(x * x + y * y + z * z)
    return (asind(z / radius), atan(y, x) * 180 / pi)
end

@testset "SatelliteSimLab" begin
    @testset "include order smoke" begin
        @test isdefined(SatelliteSimLab, :ExperimentConfig)
        @test isdefined(SatelliteSimLab, :ResolutionContext)
        @test isdefined(SatelliteSimLab, :TrafficResolutionContext)
        @test isdefined(SatelliteSimLab, :full_constellation_assessment)

        cfg = ExperimentConfig(name = "include-order-smoke", tspan = [0.0, 60.0])
        @test cfg.name == "include-order-smoke"
        @test cfg.tspan == [0.0, 60.0]
    end

    @testset "traffic time grid alignment" begin
        grid = SatelliteSimLab._simulation_time_grid_from_tspan([0.0, 60.0, 120.0], 3)
        @test grid !== nothing
        @test timeslot_offsets(grid) == [0, 60, 120]

        @test SatelliteSimLab._simulation_time_grid_from_tspan([0.0, 60.0], 3) === nothing

        single = SatelliteSimLab._simulation_time_grid_from_tspan([0.0], 1)
        @test single !== nothing
        @test timeslot_offsets(single) == [0]
        @test SatelliteSimLab._simulation_time_grid_from_tspan([60.0], 1) === nothing

        short_final = SatelliteSimLab._simulation_time_grid_from_tspan([0.0, 3.0, 6.0, 9.0, 10.0], 5)
        @test short_final !== nothing
        @test timeslot_offsets(short_final) == [0, 3, 6, 9, 10]
        @test SatelliteSimLab._simulation_time_grid_from_tspan([0.0, 3.0, 7.0, 10.0], 4) === nothing

        fuzzy = SatelliteSimLab._simulation_time_grid_from_tspan([0.0, 60.0000000004, 120.0000000003], 3)
        @test fuzzy !== nothing
        @test timeslot_offsets(fuzzy) == [0, 60, 120]
        @test SatelliteSimLab._simulation_time_grid_from_tspan([0.0, 60.001, 120.0], 3) === nothing
        @test SatelliteSimLab._simulation_time_grid_from_tspan([0.0, NaN], 2) === nothing
        @test SatelliteSimLab._simulation_time_grid_from_tspan([0.0, Inf], 2) === nothing
    end

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

    @testset "AI run_simulation traffic AON bridge" begin
        ensure_default_ai_tools!()
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
        src_lat, src_lon = _subpoint_deg(positions, 1)
        dst_lat, dst_lon = _subpoint_deg(positions, 2)

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

    @testset "AI LLMProvider fake HTTP bridge" begin
        # 起本地 fake server，拦截 OpenAI 兼容 /chat/completions 请求。
        # handler 里不写 @test（它跑在 server 的 task 上，@testset 无法收集断言），
        # 改为把请求四要素捕获到共享容器，chat() 返回后在主 task 里统一断言。
        captured = Dict{String,Any}()

        server = HTTP.serve!("127.0.0.1", 0; listenany = true) do request::HTTP.Request
            captured["method"] = request.method
            captured["target"] = String(request.target)
            captured["authorization"] = HTTP.header(request, "Authorization")
            captured["body"] = JSON.parse(String(request.body))

            response = Dict(
                "choices" => [
                    Dict(
                        "message" => Dict(
                            "content" => "fake-ok",
                            "tool_calls" => [
                                Dict(
                                    "id" => "call_1",
                                    "type" => "function",
                                    "function" => Dict(
                                        "name" => "run_simulation",
                                        "arguments" => JSON.json(Dict("duration_s" => 60)),
                                    ),
                                ),
                            ],
                        ),
                    ),
                ],
            )
            return HTTP.Response(200, ["Content-Type" => "application/json"], JSON.json(response))
        end

        try
            port = HTTP.port(server)
            provider = LLMProvider(
                key = "fake-key",
                model = "fake-model",
                url = "http://127.0.0.1:$port/v1",
                readtimeout_s = 5,
            )

            messages = [Dict("role" => "user", "content" => "hello fake")]
            tools = [
                Dict(
                    "name" => "run_simulation",
                    "description" => "fake tool",
                    "input_schema" => Dict(
                        "type" => "object",
                        "properties" => Dict("duration_s" => Dict("type" => "integer")),
                        "required" => ["duration_s"],
                    ),
                ),
            ]

            message = chat(provider, messages, tools)

            # 响应解析
            @test message.content == "fake-ok"
            @test length(message.tool_calls) == 1
            @test message.tool_calls[1].id == "call_1"
            @test message.tool_calls[1].name == "run_simulation"
            @test message.tool_calls[1].args["duration_s"] == 60

            # 请求格式 + Authorization header（主 task 断言，可靠计入 testset）
            @test captured["method"] == "POST"
            @test captured["target"] == "/v1/chat/completions"
            @test captured["authorization"] == "Bearer fake-key"

            body = captured["body"]
            @test body["model"] == "fake-model"
            @test body["messages"][1]["role"] == "user"
            @test body["messages"][1]["content"] == "hello fake"

            # tools 字段（OpenAI function 格式）
            @test body["tools"][1]["type"] == "function"
            @test body["tools"][1]["function"]["name"] == "run_simulation"
            @test body["tool_choice"] == "auto"
        finally
            close(server)
        end
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

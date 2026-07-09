using SatelliteSimCore
using SatelliteSimLab
using SatelliteSimNet
using SatelliteSimTraffic
using SatelliteSimFoundation
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

    @testset "transport-neutral streaming adapter" begin
        @test "iridium" in streaming_constellation_names()
        @test streaming_constellation_metadata("iridium")["T"] == 66

        custom = streaming_walker_config(T = 6, P = 3, F = 1, alt_km = 550.0, inc_deg = 53.0)
        simulation = prepare_streaming_simulation(
            name = "streaming-smoke",
            config = custom,
            tspan = [0.0, 10.0],
            step_s = 10.0,
            ground_stations = [(id = "beijing", name = "Beijing", lat_deg = 39.9042, lon_deg = 116.4074, alt_km = 0.0)],
        )
        @test simulation isa StreamingSimulation
        @test size(simulation.positions) == (6, 2, 3)
        @test length(simulation.isl_edges) > 0
        @test streaming_constellation_metadata(simulation)["name"] == "streaming-smoke"
        @test streaming_shell_metadata(simulation)[1]["id"] == 1

        frame = streaming_frame(simulation, 1)
        @test frame["frame_index"] == 1
        @test frame["n_total"] == 2
        @test length(frame["positions"]) == 18
        @test length(frame["isl_pairs"]) == length(simulation.isl_edges)
        @test length(frame["isl_avail"]) == length(simulation.isl_edges)
        @test frame["gsl_shape"] == [6, 1]
        @test length(frame["gsl_avail"]) == 6
        @test frame["coverage_summary"]["total"] == 1
        @test_throws BoundsError streaming_frame(simulation, 3)
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

        # Keep the package test self-contained: the production catalog's live
        # Celestrak file is intentionally ignored and not guaranteed to exist
        # in a fresh clone.  This small checked-in fixture exercises the same
        # literal/file TLE path without a network or local data dependency.
        tle_fixture = joinpath(@__DIR__, "fixtures", "starlink_sample.tle")
        result_json = execute_tool(
            "run_simulation",
            Dict(
                "constellation" => "starlink_tle",
                "tle" => tle_fixture,
                "topology" => "balanced",
                "propagator" => "tle_based",
                "duration_s" => 60,
                "steps" => 3,
                "max_sats" => 6,
            ),
        )
        result = JSON.parse(result_json)
        @test !haskey(result, "error")
        @test result["propagator"] == "tle_based"
        @test result["n_satellites"] == 6
        @test result["tle_source"] == 6
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

    @testset "AI SimAgent tool loop fake HTTP bridge" begin
        # 复现 probe 的两轮工具循环：第 1 轮 fake server 返回 tool_call(list_available)，
        # SimAgent 真实执行该工具，把结果作为 tool 消息回传；第 2 轮返回最终文本答案。
        # handler 只按请求序号返回对应响应并捕获 body，全部断言放在主 task。
        received = Vector{Dict{String,Any}}()
        headers = Vector{Union{Nothing,String}}()
        methods = String[]
        targets = String[]

        server = HTTP.serve!("127.0.0.1", 0; listenany = true) do request::HTTP.Request
            push!(methods, request.method)
            push!(targets, String(request.target))
            push!(headers, HTTP.header(request, "Authorization"))
            body = JSON.parse(String(request.body))
            push!(received, body)

            if length(received) == 1
                # 第 1 轮：要求调用 list_available(propagators)
                response = Dict(
                    "choices" => [
                        Dict(
                            "message" => Dict(
                                "content" => nothing,
                                "tool_calls" => [
                                    Dict(
                                        "id" => "call_list_available_1",
                                        "type" => "function",
                                        "function" => Dict(
                                            "name" => "list_available",
                                            "arguments" => JSON.json(Dict("what" => "propagators")),
                                        ),
                                    ),
                                ],
                            ),
                        ),
                    ],
                )
                return HTTP.Response(200, ["Content-Type" => "application/json"], JSON.json(response))
            elseif length(received) == 2
                # 第 2 轮：工具结果已回传，返回最终答案
                response = Dict(
                    "choices" => [
                        Dict("message" => Dict("content" => "传播器包括 fast/balanced/precise/tle_based。")),
                    ],
                )
                return HTTP.Response(200, ["Content-Type" => "application/json"], JSON.json(response))
            end
            return HTTP.Response(500, JSON.json(Dict("error" => "unexpected request")))
        end

        session_id = "test_fake_openai_tool_loop_$(rand(UInt))"
        try
            port = HTTP.port(server)
            provider = LLMProvider(
                key = "fake-key",
                model = "fake-model",
                url = "http://127.0.0.1:$port/v1",
                readtimeout_s = 5,
            )
            agent = SimAgent(provider; session_id = session_id)
            reply = run_agent(agent, "列出可用传播器")

            # 最终答案 + 工具循环发生
            @test reply == "传播器包括 fast/balanced/precise/tle_based。"
            @test length(received) == 2
            @test count(m -> get(m, "role", "") == "tool", agent.messages) == 1

            # 两轮请求都命中 OpenAI 兼容端点 + Authorization
            @test methods == ["POST", "POST"]
            @test targets == ["/v1/chat/completions", "/v1/chat/completions"]
            @test headers == ["Bearer fake-key", "Bearer fake-key"]

            # 第 1 轮请求格式：system + user 消息、tools 字段、tool_choice
            first_body = received[1]
            @test first_body["messages"][1]["role"] == "system"
            @test first_body["messages"][2]["role"] == "user"
            @test first_body["messages"][2]["content"] == "列出可用传播器"
            @test first_body["tools"][1]["type"] == "function"
            @test first_body["tool_choice"] == "auto"

            # 第 2 轮请求：assistant tool_call + tool 结果消息（含真实工具输出 tle_based）
            second_msgs = received[2]["messages"]
            assistant_msg = second_msgs[end - 1]
            tool_msg = second_msgs[end]
            @test assistant_msg["role"] == "assistant"
            @test assistant_msg["tool_calls"][1]["id"] == "call_list_available_1"
            @test tool_msg["role"] == "tool"
            @test tool_msg["tool_call_id"] == "call_list_available_1"
            @test occursin("tle_based", tool_msg["content"])
        finally
            close(server)
            session_dir = dirname(SessionMemory(session_id = session_id).transcript_path)
            isdir(session_dir) && rm(session_dir; recursive = true, force = true)
            clear_hooks!()
        end
    end

    @testset "AI team graph run_simulation (mock provider)" begin
        # 镜像自 scripts/probe_ai_team_graph_run_simulation.jl：
        # 用 MockProvider 脚本化 planner -> runner -> reviewer，确认 runner 真实执行 run_simulation。
        # 确定性、无真实 LLM / API key / 网络。
        cleanup_team_sessions = function (sid::String)
            for suffix in ("", "_planner", "_runner", "_reviewer")
                path = joinpath("data", "sessions", sid * suffix)
                isdir(path) && rm(path; recursive = true, force = true)
            end
        end

        session_id = "lab_ai_team_graph_run_simulation_$(rand(UInt))"

        try
            provider = MockProvider([
                AssistantMessage("计划：运行一个 6 颗星的小规模仿真，然后审查指标。", ToolCall[]),
                AssistantMessage("", [
                    ToolCall(
                        "call_runner_sim",
                        "run_simulation",
                        Dict{String,Any}(
                            "constellation" => "walker 6/3/1",
                            "duration_s" => 60,
                            "steps" => 2,
                            "topology" => "minimal",
                            "propagator" => "fast",
                        ),
                    ),
                ]),
                AssistantMessage(
                    "执行完成：仿真工具返回 coverage_ratio、avg_latency_ms、connectivity_ratio。",
                    ToolCall[],
                ),
                AssistantMessage("最终结论：通过。结果可信，但规模很小，只能作为 smoke。", ToolCall[]),
            ])

            team = AgentTeam(provider; session_id = session_id)
            result = run_team_graph(team, default_team_graph(), "用多智能体跑一个最小仿真实验")

            @test result.state.status == :completed
            @test [msg.from for msg in result.transcript] == ["planner", "runner", "reviewer"]
            @test occursin("最终结论", result.final_answer)

            runner_messages = team.agents["runner"].messages
            tool_messages = [msg for msg in runner_messages if get(msg, "role", "") == "tool"]
            @test length(tool_messages) == 1

            payload = JSON.parse(tool_messages[1]["content"]; allownan = true)
            @test haskey(payload, "coverage_ratio")
            @test haskey(payload, "avg_latency_ms")
            @test haskey(payload, "connectivity_ratio")
            @test payload["n_satellites"] == 6

            runner_ledger = ledger_path(team.agents["runner"].memory)
            @test isfile(runner_ledger)
            @test any(
                line -> occursin("\"event_type\":\"tool_call\"", line) &&
                        occursin("\"tool\":\"run_simulation\"", line) &&
                        occursin("\"status\":\"succeeded\"", line),
                readlines(runner_ledger),
            )
        finally
            cleanup_team_sessions(session_id)
            clear_hooks!()
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

# --- from main: topology candidate / traffic reachability regression ---
struct SingleCandidateStrategy <: AbstractTopologyStrategy
    edge::Tuple{Int,Int}
end

function SatelliteSimNet.generate_topology(
    strategy::SingleCandidateStrategy,
    ::Int,
    ::Int,
)::TopologyOutput
    return TopologyOutput(Tuple{Int,Int}[strategy.edge], Tuple{Int,Int}[], "SingleCandidate")
end

function _distance_km(positions::Array{Float64,3}, a::Int, b::Int, time_index::Int)::Float64
    return sqrt(sum((positions[a, time_index, k] - positions[b, time_index, k])^2 for k in 1:3))
end

function _subpoint_ground_station(
    id::Int,
    name::String,
    positions::Array{Float64,3},
    satellite_id::Int,
    time_index::Int,
)::GroundStation
    x = positions[satellite_id, time_index, 1]
    y = positions[satellite_id, time_index, 2]
    z = positions[satellite_id, time_index, 3]
    latitude_deg = atan(z, hypot(x, y)) * 180 / pi
    longitude_deg = atan(y, x) * 180 / pi
    return GroundStation(id, name, GeodeticPosition(latitude_deg, longitude_deg, 0.0))
end

@testset "SatelliteSimLab network traffic candidates" begin
    base_config = ExperimentConfig(
        name = "candidate-probe",
        constellation_params = Dict(
            :T => 6.0,
            :P => 3.0,
            :F => 1.0,
            :alt_km => 550.0,
            :inc_deg => 53.0,
        ),
        tspan = [0.0, 3000.0],
        topology_strategy = SingleCandidateStrategy((1, 4)),
        constraints = PhysicalConstraints(
            isl_max_range_km = 5000.0,
            isl_require_los = false,
            isl_max_capacity_mbps = 1000.0,
            gsl_min_elevation_deg = -90.0,
            gsl_max_range_km = 1.0e9,
            gsl_base_capacity_mbps = 1000.0,
        ),
        traffic = TrafficDemand[],
    )
    _, positions = propagate_constellation_positions(base_config)

    first_distance = _distance_km(positions, 1, 4, 1)
    last_distance = _distance_km(positions, 1, 4, 2)
    @test first_distance < last_distance

    constraints = PhysicalConstraints(
        isl_max_range_km = (first_distance + last_distance) / 2,
        isl_require_los = false,
        isl_max_capacity_mbps = 1000.0,
        gsl_min_elevation_deg = -90.0,
        gsl_max_range_km = 1.0e9,
        gsl_base_capacity_mbps = 1000.0,
    )
    demand = TrafficDemand(
        id = 1,
        source_ground_id = 1,
        destination_ground_id = 2,
        start_elapsed_s = 0,
        end_elapsed_s = 3001,
        rate_mbps = 100.0,
    )
    config = ExperimentConfig(
        name = "traffic-candidates-use-full-topology",
        constellation_params = Dict(
            :T => 6.0,
            :P => 3.0,
            :F => 1.0,
            :alt_km => 550.0,
            :inc_deg => 53.0,
        ),
        tspan = [0.0, 3000.0],
        topology_strategy = SingleCandidateStrategy((1, 4)),
        routing_algorithm = DijkstraRouting(),
        constraints = constraints,
        traffic = TrafficDemand[demand],
        ground_stations = GroundStation[
            _subpoint_ground_station(1, "source", positions, 1, 1),
            _subpoint_ground_station(2, "destination", positions, 4, 1),
        ],
    )

    result = full_constellation_assessment(config)
    @test result.traffic_evaluation !== nothing

    assignments_t1 = SatelliteSimTraffic.traffic_assignments_at(result.traffic_evaluation, 1)
    @test length(assignments_t1) == 1
    @test assignments_t1[1].route.reachable
    @test assignments_t1[1].route.satellite_path == [1, 4]
    @test assignments_t1[1].carried_mbps == 100.0

    assignments_t2 = SatelliteSimTraffic.traffic_assignments_at(result.traffic_evaluation, 2)
    @test length(assignments_t2) == 1
    @test !assignments_t2[1].route.reachable
    @test assignments_t2[1].route.reason == :isl_unreachable
    @test assignments_t2[1].dropped_mbps == 100.0
end

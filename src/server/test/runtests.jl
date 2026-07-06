using SatelliteSimServer
using SatelliteSimCore
using SatelliteSimLab
using JSON3
using Test

@testset "SatelliteSimServer" begin

    @testset "protocol: request parsing" begin
        r = parse_request("""{"type":"list_constellations"}""")
        @test r isa ListConstellationsReq

        r = parse_request("""{"type":"describe_constellation","name":"iridium"}""")
        @test r isa DescribeConstellationReq
        @test r.name == "iridium"

        # start_simulation 最小字段（用默认值）
        r = parse_request("""{"type":"start_simulation","name":"iridium"}""")
        @test r isa StartSimulationReq
        @test r.name == "iridium"
        @test r.tspan == [0.0, 600.0]
        @test r.step_s == 10.0

        # start_simulation 完整字段
        r = parse_request("""{"type":"start_simulation","name":"walker48","tspan":[0.0,30.0],"step_s":5.0,"propagator":"j4","fps":20.0}""")
        @test r.tspan == [0.0, 30.0]
        @test r.propagator == "j4"
        @test r.fps == 20.0

        r = parse_request("""{"type":"start_simulation","name":"iridium","ground_stations":[{"id":"beijing","name":"Beijing","lat_deg":39.9042,"lon_deg":116.4074,"alt_km":0.0}],"include_gsl":true,"include_coverage":true}""")
        @test length(r.ground_stations) == 1
        @test r.ground_stations[1].id == "beijing"
        @test r.ground_stations[1].lat_deg ≈ 39.9042
        @test r.include_gsl
        @test r.include_coverage

        r = parse_request("""{"type":"stop_simulation","session_id":"abc"}""")
        @test r isa StopSimulationReq
        @test r.session_id == "abc"

        r = parse_request("""{"type":"ai_trace","session_id":"abc","mode":"replay_plan"}""")
        @test r isa AITraceReq
        @test r.session_id == "abc"
        @test r.mode == "replay_plan"

        r = parse_request("""{"type":"ai_checkpoint","session_id":"abc"}""")
        @test r isa AICheckpointReq
        @test r.session_id == "abc"

        # 未知 type 报错
        @test_throws ArgumentError parse_request("""{"type":"foo"}""")
    end

    @testset "protocol: response serialization" begin
        resp = ListConstellationsResp(names = ["a", "b"])
        s = JSON3.write(resp)
        back = JSON3.read(s)
        @test back.type == "list_constellations_response"
        @test back.ok == true
        @test back.names == ["a", "b"]

        err = ErrorResponse(message = "boom")
        s = JSON3.write(err)
        back = JSON3.read(s)
        @test back.type == "error"
        @test back.message == "boom"
    end

    @testset "handlers: list_constellations" begin
        resp, sess = dispatch_request(ListConstellationsReq())
        @test sess === nothing
        @test resp.ok
        @test "iridium" in resp.names
        @test "walker48" in resp.names
    end

    @testset "handlers: describe_constellation" begin
        req = DescribeConstellationReq(name = "iridium")
        resp, sess = dispatch_request(req)
        @test sess === nothing
        @test resp.ok
        @test resp.T == 66
        @test resp.P == 6
        @test resp.F == 2
        @test resp.alt_km == 780.0
        @test resp.inc_deg == 86.4

        # 不存在
        req = DescribeConstellationReq(name = "no_such")
        @test_throws ErrorException dispatch_request(req)
    end

    @testset "handlers: start/stop_simulation" begin
        req = StartSimulationReq(name = "walker48", tspan = [0.0, 30.0], step_s = 10.0)
        resp, sess = dispatch_request(req)
        try
            @test resp.ok
            @test resp.n_sat == 48
            @test resp.n_time == 4
            @test length(resp.session_id) == 8
            @test sess !== nothing
            @test size(sess.positions) == (48, 4, 3)
            @test resp.constellation["T"] == 48
            @test resp.constellation["P"] == 8
            @test length(resp.shells) == 1
            @test resp.shells[1]["alt_km"] == 550.0

            # stop
            stop_req = StopSimulationReq(session_id = resp.session_id)
            stop_resp, _ = dispatch_request(stop_req)
            @test stop_resp.ok
            @test !haskey(SESSIONS, resp.session_id)

            # stop 已停止的 → 报错（session 已从 SESSIONS 移除）
            @test_throws ArgumentError dispatch_request(stop_req)
        finally
            # 清理（万一断言失败也要清）
            haskey(SESSIONS, resp.session_id) && stop_session!(resp.session_id)
        end
    end

    @testset "streamer: frame_payload" begin
        session = start_session(;
            name = "iridium", tspan = [0.0, 30.0],
            step_s = 10.0, propagator = "j2", fps = 30.0,
        )
        try
            payload = frame_payload(session, 1)
            @test payload["type"] == "frame"
            @test payload["session_id"] == session.id
            @test payload["t"] == 0.0
            @test payload["frame_index"] == 1
            @test payload["n_total"] == 4
            n_sat = size(session.positions, 1)
            @test length(payload["positions"]) == 3 * n_sat
            @test length(payload["isl_pairs"]) == length(payload["isl_avail"])
            @test length(payload["isl_pairs"]) == length(session.isl_edges)

            # JSON round-trip
            s = JSON3.write(payload)
            back = JSON3.read(s)
            @test back.type == "frame"

            # 第二帧 t != 0
            payload2 = frame_payload(session, 2)
            @test payload2["t"] ≈ 10.0

            gs_session = start_session(;
                name = "iridium", tspan = [0.0, 10.0], step_s = 10.0,
                ground_stations = [GroundStationSpec(id = "beijing", name = "Beijing", lat_deg = 39.9042, lon_deg = 116.4074, alt_km = 0.0)],
            )
            try
                gsl_payload = frame_payload(gs_session, 1)
                @test gsl_payload["gsl_shape"] == [66, 1]
                @test length(gsl_payload["gsl_avail"]) == 66
                @test haskey(gsl_payload, "gsl_pairs")
                @test haskey(gsl_payload, "ground_stations")
                @test gsl_payload["coverage_summary"]["total"] == 1
            finally
                stop_session!(gs_session.id)
            end

            # 越界
            @test_throws BoundsError frame_payload(session, 99)
        finally
            stop_session!(session.id)
        end
    end

    @testset "physical sanity: Iridium has reasonable ISL availability" begin
        # Iridium 极轨，应有较高 ISL 可用率（验证物理层真在工作）
        session = start_session(;
            name = "iridium", tspan = [0.0, 10.0], step_s = 10.0,
            propagator = "j2", fps = 10.0,
        )
        try
            payload = frame_payload(session, 1)
            n_total = length(payload["isl_avail"])
            n_avail = count(payload["isl_avail"])
            avail_ratio = n_avail / n_total
            @test avail_ratio > 0.5   # Iridium 应至少 50% 可用
        finally
            stop_session!(session.id)
        end
    end

    @testset "propagator selection" begin
        # 不同传播器都应跑通
        for prop in ("two_body", "j2", "j4")
            session = start_session(;
                name = "walker48", tspan = [0.0, 10.0], step_s = 10.0,
                propagator = prop, fps = 10.0,
            )
            try
                @test size(session.positions) == (48, 2, 3)
                # 位置不该全是 NaN
                @test !any(isnan, session.positions)
            finally
                stop_session!(session.id)
            end
        end
    end

    @testset "AI trace/checkpoint endpoints" begin
        session_id = "server_ai_$(rand(UInt))"
        mem = SatelliteSimLab.SessionMemory(session_id = session_id)
        session_dir = dirname(mem.transcript_path)
        try
            SatelliteSimLab.record_ledger_event!(mem, Dict{String,Any}(
                "event_type" => "tool_call",
                "tool" => "list_available",
                "args" => Dict("what" => "all"),
                "status" => "succeeded",
            ))
            trace_resp, sess = dispatch_request(AITraceReq(session_id = session_id))
            @test sess === nothing
            @test trace_resp.ok
            @test trace_resp.mode == "timeline"
            @test any(occursin("tool_call", item) for item in trace_resp.items)

            state = SatelliteSimLab.TeamState("req", SatelliteSimLab.TeamMessage[], Dict{String,Any}(), "", 0, :completed)
            team = SatelliteSimLab.AgentTeam(SatelliteSimLab.MockProvider(SatelliteSimLab.AssistantMessage[]); session_id = session_id)
            SatelliteSimLab.save_team_graph_checkpoint!(team, state)
            chk_resp, sess2 = dispatch_request(AICheckpointReq(session_id = session_id))
            @test sess2 === nothing
            @test chk_resp.ok
            @test JSON3.read(chk_resp.summary_json).status == "completed"
        finally
            isdir(session_dir) && rm(session_dir; recursive = true, force = true)
            SatelliteSimLab.clear_hooks!()
        end
    end
end

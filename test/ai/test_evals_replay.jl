using Test
using JSON
using SatelliteSimLab

@testset "AI eval harness and replay" begin
    @testset "agent eval checks tools and final answer" begin
        case = SatelliteSimLab.AgentEvalCase(
            id = "list-propagators",
            input = "列出传播器",
            responses = [
                SatelliteSimLab.AssistantMessage("", [
                    SatelliteSimLab.ToolCall("call_1", "list_available", Dict{String,Any}("what" => "propagators")),
                ]),
                SatelliteSimLab.AssistantMessage("可用传播器：fast/balanced/precise/tle_based", SatelliteSimLab.ToolCall[]),
            ],
            expected_contains = ["tle_based"],
            expected_tools = ["list_available"],
        )

        result = SatelliteSimLab.run_agent_eval(case; session_id = "test_eval_agent_$(rand(UInt))")
        @test result.passed
        @test result.tool_calls == ["list_available"]
        @test isempty(result.failures)
    end

    @testset "team graph eval and suite report" begin
        case = SatelliteSimLab.AgentEvalCase(
            id = "team-linear",
            input = "跑一个团队任务",
            responses = [
                SatelliteSimLab.AssistantMessage("计划完成", SatelliteSimLab.ToolCall[]),
                SatelliteSimLab.AssistantMessage("执行完成", SatelliteSimLab.ToolCall[]),
                SatelliteSimLab.AssistantMessage("最终结论：通过", SatelliteSimLab.ToolCall[]),
            ],
            expected_contains = ["通过"],
            mode = :team_graph,
        )

        suite = SatelliteSimLab.run_agent_eval_suite([case]; session_prefix = "test_eval_suite_$(rand(UInt))")
        report = SatelliteSimLab.eval_report(suite)
        @test report["total"] == 1
        @test report["passed"] == 1
        @test report["pass_rate"] == 1.0
        @test report["cases"][1]["id"] == "team-linear"
    end

    @testset "deterministic replay dry run and execution" begin
        trace_session = "test_replay_$(rand(UInt))"
        mem = SatelliteSimLab.SessionMemory(session_id = trace_session)
        session_dir = dirname(mem.transcript_path)

        try
            original = SatelliteSimLab.execute_tool("list_available", Dict{String,Any}("what" => "propagators"))
            SatelliteSimLab.record_ledger_event!(mem, Dict{String,Any}(
                "event_type" => "tool_call",
                "tool" => "list_available",
                "args" => Dict("what" => "propagators"),
                "args_hash" => SatelliteSimLab.stable_digest(Dict("what" => "propagators")),
                "status" => "succeeded",
                "result_hash" => SatelliteSimLab.stable_digest(original),
            ))

            trace = SatelliteSimLab.load_agent_trace(mem)
            dry = SatelliteSimLab.replay_tools(trace; dry_run = true)
            @test dry.dry_run
            @test length(dry.steps) == 1
            @test dry.steps[1].status == "planned"

            replayed = SatelliteSimLab.replay_tools(trace; dry_run = false, verify_hash = true)
            @test !replayed.dry_run
            @test replayed.steps[1].tool == "list_available"
            @test replayed.steps[1].matched_hash === true

            report = SatelliteSimLab.replay_report(replayed)
            @test report["total"] == 1
            @test report["mismatches"] == 0
            @test JSON.parse(replayed.steps[1].result)["propagators"] == ["fast", "balanced", "precise", "tle_based"]
        finally
            isdir(session_dir) && rm(session_dir; recursive = true, force = true)
            SatelliteSimLab.clear_hooks!()
        end
    end
end

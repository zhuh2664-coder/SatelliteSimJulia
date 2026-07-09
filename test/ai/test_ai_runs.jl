using Test
using SatelliteSimLab

function _cleanup_ai_run_session(session_id)
    for suffix in ("", "_planner", "_runner", "_reviewer")
        path = joinpath("data", "sessions", session_id * suffix)
        isdir(path) && rm(path; recursive = true, force = true)
    end
    SatelliteSimLab.clear_hooks!()
end

@testset "AI run control plane" begin
    @testset "team graph run lifecycle" begin
        session_id = "test_ai_run_team_$(rand(UInt))"
        run_id = "run_team_$(rand(UInt))"
        try
            SatelliteSimLab.clear_ai_runs!()
            provider = SatelliteSimLab.MockProvider([
                SatelliteSimLab.AssistantMessage("计划完成\nARTIFACT plan {\"goal\":\"coverage\"}", SatelliteSimLab.ToolCall[]),
                SatelliteSimLab.AssistantMessage("执行完成\nARTIFACT result {\"coverage\":0.91}", SatelliteSimLab.ToolCall[]),
                SatelliteSimLab.AssistantMessage("最终结论：通过", SatelliteSimLab.ToolCall[]),
            ])
            config = SatelliteSimLab.AIRunConfig(
                id = run_id,
                user_input = "运行团队任务",
                mode = :team_graph,
                session_id = session_id,
                checkpoint = true,
            )
            result = SatelliteSimLab.start_ai_run(provider, config)

            @test result.id == run_id
            @test result.final_answer == "最终结论：通过"
            @test result.artifacts["plan"]["goal"] == "coverage"
            @test result.checkpoint_summary["status"] == "completed"
            @test any(e -> e.event_type == "ai_run_completed", result.trace.events)

            status = SatelliteSimLab.get_ai_run_status(run_id)
            @test status.state == :completed
            @test status.completed_at !== nothing
            @test SatelliteSimLab.get_ai_run_result(run_id) === result
            @test run_id in [s.id for s in SatelliteSimLab.list_ai_runs()]
        finally
            _cleanup_ai_run_session(session_id)
            SatelliteSimLab.clear_ai_runs!()
        end
    end

    @testset "agent run lifecycle" begin
        session_id = "test_ai_run_agent_$(rand(UInt))"
        run_id = "run_agent_$(rand(UInt))"
        try
            SatelliteSimLab.clear_ai_runs!()
            provider = SatelliteSimLab.MockProvider([
                SatelliteSimLab.AssistantMessage("", [
                    SatelliteSimLab.ToolCall("call_1", "list_available", Dict{String,Any}("what" => "propagators")),
                ]),
                SatelliteSimLab.AssistantMessage("传播器列表完成", SatelliteSimLab.ToolCall[]),
            ])
            result = SatelliteSimLab.start_ai_run(provider, SatelliteSimLab.AIRunConfig(
                id = run_id,
                user_input = "列出传播器",
                mode = :agent,
                session_id = session_id,
            ))

            @test result.final_answer == "传播器列表完成"
            @test isempty(result.artifacts)
            @test any(e -> e.event_type == "tool_call", result.trace.events)
            @test SatelliteSimLab.get_ai_run_status(run_id).state == :completed
        finally
            _cleanup_ai_run_session(session_id)
            SatelliteSimLab.clear_ai_runs!()
        end
    end

    @testset "failed run records status" begin
        session_id = "test_ai_run_failed_$(rand(UInt))"
        run_id = "run_failed_$(rand(UInt))"
        try
            SatelliteSimLab.clear_ai_runs!()
            provider = SatelliteSimLab.MockProvider(SatelliteSimLab.AssistantMessage[])
            config = SatelliteSimLab.AIRunConfig(
                id = run_id,
                user_input = "bad",
                mode = :unknown,
                session_id = session_id,
            )
            @test_throws ErrorException SatelliteSimLab.start_ai_run(provider, config)
            status = SatelliteSimLab.get_ai_run_status(run_id)
            @test status.state == :failed
            @test occursin("unknown AI run mode", status.error)
        finally
            _cleanup_ai_run_session(session_id)
            SatelliteSimLab.clear_ai_runs!()
        end
    end
end

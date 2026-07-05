using Test
using Dates
using SatelliteSimLab

function _cleanup_team_checkpoint_sessions(session_id)
    for suffix in ("", "_planner", "_runner", "_reviewer")
        path = joinpath("data", "sessions", session_id * suffix)
        isdir(path) && rm(path; recursive = true, force = true)
    end
end

@testset "AI team graph checkpoint" begin
    @testset "checkpoint captures final state" begin
        session_id = "test_team_checkpoint_$(rand(UInt))"
        try
            provider = SatelliteSimLab.MockProvider([
                SatelliteSimLab.AssistantMessage("计划完成", SatelliteSimLab.ToolCall[]),
                SatelliteSimLab.AssistantMessage("执行完成", SatelliteSimLab.ToolCall[]),
                SatelliteSimLab.AssistantMessage("最终结论：通过", SatelliteSimLab.ToolCall[]),
            ])
            team = SatelliteSimLab.AgentTeam(provider; session_id = session_id)
            path = SatelliteSimLab.team_graph_checkpoint_path(team)
            result = SatelliteSimLab.run_team_graph(
                team,
                SatelliteSimLab.default_team_graph(),
                "跑一个可恢复测试";
                checkpoint = true,
            )

            @test isfile(path)
            loaded = SatelliteSimLab.load_team_graph_checkpoint(path)
            @test loaded.user_input == "跑一个可恢复测试"
            @test loaded.status == :completed
            @test loaded.step == result.state.step
            @test length(loaded.transcript) == 3
            @test loaded.transcript[end].content == "最终结论：通过"

            summary = SatelliteSimLab.checkpoint_summary(loaded)
            @test summary["status"] == "completed"
            @test summary["messages"] == 3
            @test summary["last_agent"] == "reviewer"

            ledger = SatelliteSimLab.ledger_path(team.shared_memory)
            @test any(occursin("team_graph_checkpoint", line) for line in readlines(ledger))
        finally
            _cleanup_team_checkpoint_sessions(session_id)
            SatelliteSimLab.clear_hooks!()
        end
    end

    @testset "state roundtrip preserves artifacts" begin
        msg = SatelliteSimLab.TeamMessage("planner", "runner", :planner, "计划", now())
        state = SatelliteSimLab.TeamState(
            "用户需求",
            [msg],
            Dict{String,Any}("plan_id" => "p1"),
            "runner",
            1,
            :running,
        )

        restored = SatelliteSimLab.team_state_from_dict(SatelliteSimLab.team_state_to_dict(state))
        @test restored.user_input == state.user_input
        @test restored.current_node == "runner"
        @test restored.artifacts["plan_id"] == "p1"
        @test restored.transcript[1].from == "planner"
        @test restored.transcript[1].role == :planner
    end
end

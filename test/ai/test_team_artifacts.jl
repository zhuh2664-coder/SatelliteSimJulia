using Test
using SatelliteSimLab

@testset "AI team structured artifacts" begin
    session_id = "test_team_artifacts_$(rand(UInt))"
    try
        provider = SatelliteSimLab.MockProvider([
            SatelliteSimLab.AssistantMessage("计划完成\nARTIFACT plan {\"goal\":\"coverage\",\"steps\":[\"run\"]}", SatelliteSimLab.ToolCall[]),
            SatelliteSimLab.AssistantMessage("执行完成\nARTIFACT result {\"coverage\":0.9}", SatelliteSimLab.ToolCall[]),
            SatelliteSimLab.AssistantMessage("最终结论：通过", SatelliteSimLab.ToolCall[]),
        ])
        team = SatelliteSimLab.AgentTeam(provider; session_id = session_id)
        result = SatelliteSimLab.run_team_graph(
            team,
            SatelliteSimLab.default_team_graph(),
            "跑一个结构化团队任务";
            checkpoint = true,
        )

        @test haskey(result.state.artifacts, "plan")
        @test result.state.artifacts["plan"]["goal"] == "coverage"
        @test result.state.artifacts["result"]["coverage"] == 0.9

        summary = SatelliteSimLab.team_artifact_summary(result.state)
        @test summary["count"] == 2
        @test summary["keys"] == ["plan", "result"]

        loaded = SatelliteSimLab.load_team_graph_checkpoint(SatelliteSimLab.team_graph_checkpoint_path(team))
        @test loaded.artifacts["plan"]["steps"] == ["run"]
        @test loaded.artifacts["result"]["coverage"] == 0.9

        ledger = SatelliteSimLab.ledger_path(team.shared_memory)
        @test any(occursin("team_artifacts_updated", line) for line in readlines(ledger))
    finally
        for suffix in ("", "_planner", "_runner", "_reviewer")
            path = joinpath("data", "sessions", session_id * suffix)
            isdir(path) && rm(path; recursive = true, force = true)
        end
        SatelliteSimLab.clear_hooks!()
    end
end

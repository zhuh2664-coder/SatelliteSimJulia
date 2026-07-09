using Test
using SatelliteSimLab

function _cleanup_team_sessions(session_id)
    for suffix in ("", "_planner", "_runner", "_reviewer")
        path = joinpath("data", "sessions", session_id * suffix)
        isdir(path) && rm(path; recursive = true, force = true)
    end
end

@testset "AI team graph" begin
    @testset "linear graph completes" begin
        session_id = "test_team_graph_linear_$(rand(UInt))"
        try
            provider = SatelliteSimLab.MockProvider([
                SatelliteSimLab.AssistantMessage("计划完成", SatelliteSimLab.ToolCall[]),
                SatelliteSimLab.AssistantMessage("执行完成", SatelliteSimLab.ToolCall[]),
                SatelliteSimLab.AssistantMessage("最终结论：通过", SatelliteSimLab.ToolCall[]),
            ])
            team = SatelliteSimLab.AgentTeam(provider; session_id = session_id)
            result = SatelliteSimLab.run_team_graph(team, SatelliteSimLab.default_team_graph(), "跑一个测试")

            @test result.final_answer == "最终结论：通过"
            @test [m.from for m in result.transcript] == ["planner", "runner", "reviewer"]
            @test result.state.status == :completed
            ledger = SatelliteSimLab.ledger_path(team.shared_memory)
            @test any(occursin("team_graph_finished", line) for line in readlines(ledger))
        finally
            _cleanup_team_sessions(session_id)
            SatelliteSimLab.clear_hooks!()
        end
    end

    @testset "reviewer can route back to runner" begin
        session_id = "test_team_graph_revise_$(rand(UInt))"
        try
            provider = SatelliteSimLab.MockProvider([
                SatelliteSimLab.AssistantMessage("计划完成", SatelliteSimLab.ToolCall[]),
                SatelliteSimLab.AssistantMessage("第一次执行结果", SatelliteSimLab.ToolCall[]),
                SatelliteSimLab.AssistantMessage("需要返工：补充传播器列表", SatelliteSimLab.ToolCall[]),
                SatelliteSimLab.AssistantMessage("第二次执行完成", SatelliteSimLab.ToolCall[]),
                SatelliteSimLab.AssistantMessage("最终结论：通过", SatelliteSimLab.ToolCall[]),
            ])
            team = SatelliteSimLab.AgentTeam(provider; session_id = session_id)
            result = SatelliteSimLab.run_team_graph(team, SatelliteSimLab.default_team_graph(), "需要可审查的实验")

            @test count(m -> m.from == "runner", result.transcript) == 2
            @test count(m -> m.from == "reviewer", result.transcript) == 2
            @test result.state.status == :completed
            ledger = SatelliteSimLab.ledger_path(team.shared_memory)
            @test any(occursin("routing_decision", line) && occursin("\"to\":\"runner\"", line) for line in readlines(ledger))
        finally
            _cleanup_team_sessions(session_id)
            SatelliteSimLab.clear_hooks!()
        end
    end

    @testset "max steps stops revise loop" begin
        session_id = "test_team_graph_max_$(rand(UInt))"
        try
            provider = SatelliteSimLab.MockProvider([
                SatelliteSimLab.AssistantMessage("计划完成", SatelliteSimLab.ToolCall[]),
                SatelliteSimLab.AssistantMessage("第一次执行结果", SatelliteSimLab.ToolCall[]),
                SatelliteSimLab.AssistantMessage("需要返工", SatelliteSimLab.ToolCall[]),
                SatelliteSimLab.AssistantMessage("第二次执行结果", SatelliteSimLab.ToolCall[]),
            ])
            team = SatelliteSimLab.AgentTeam(provider; session_id = session_id)
            graph = SatelliteSimLab.default_team_graph(; max_steps = 4)
            result = SatelliteSimLab.run_team_graph(team, graph, "触发返工循环")

            @test result.state.status == :max_steps_reached
            @test length(result.transcript) == 4
            ledger = SatelliteSimLab.ledger_path(team.shared_memory)
            @test any(occursin("team_graph_finished", line) && occursin("max_steps_reached", line) for line in readlines(ledger))
        finally
            _cleanup_team_sessions(session_id)
            SatelliteSimLab.clear_hooks!()
        end
    end
end

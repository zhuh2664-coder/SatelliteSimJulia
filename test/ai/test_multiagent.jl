using Test
using SatelliteSimLab

@testset "AI multi-agent orchestration" begin
    session_id = "test_multiagent_$(rand(UInt))"
    shared_mem = SatelliteSimLab.SessionMemory(session_id = session_id)
    session_dir = dirname(shared_mem.transcript_path)

    try
        provider = SatelliteSimLab.MockProvider([
            SatelliteSimLab.AssistantMessage("计划：先列出传播器，再运行小规模实验。", SatelliteSimLab.ToolCall[]),
            SatelliteSimLab.AssistantMessage("", [
                SatelliteSimLab.ToolCall("call_runner_1", "list_available", Dict{String,Any}("what" => "propagators")),
            ]),
            SatelliteSimLab.AssistantMessage("执行完成。", SatelliteSimLab.ToolCall[]),
            SatelliteSimLab.AssistantMessage("最终结论：可用传播器已确认。", SatelliteSimLab.ToolCall[]),
        ])

        team = SatelliteSimLab.AgentTeam(provider; session_id = session_id)
        result = SatelliteSimLab.run_team(team, "规划并执行一个传播器可用性检查")

        @test result.final_answer == "最终结论：可用传播器已确认。"
        @test length(result.transcript) == 3
        @test result.transcript[1].from == "planner"
        @test result.transcript[2].from == "runner"
        @test result.transcript[3].from == "reviewer"
        @test any(m -> get(m, "role", "") == "tool", team.agents["runner"].messages)

        ledger = SatelliteSimLab.ledger_path(team.shared_memory)
        @test isfile(ledger)
        @test any(occursin("\"event_type\":\"agent_message\"", line) for line in readlines(ledger))
    finally
        isdir(session_dir) && rm(session_dir; recursive = true, force = true)
        for suffix in ("_planner", "_runner", "_reviewer")
            p = joinpath("data", "sessions", session_id * suffix)
            isdir(p) && rm(p; recursive = true, force = true)
        end
        SatelliteSimLab.clear_hooks!()
    end
end

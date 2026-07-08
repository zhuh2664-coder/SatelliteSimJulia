using Test
using SatelliteSimLab

@testset "AI mock provider e2e" begin
    session_id = "test_mock_provider_$(rand(UInt))"
    mem = SatelliteSimLab.SessionMemory(session_id = session_id)
    session_dir = dirname(mem.transcript_path)

    try
        provider = SatelliteSimLab.MockProvider([
            SatelliteSimLab.AssistantMessage("", [
                SatelliteSimLab.ToolCall("call_1", "list_available", Dict{String,Any}("what" => "propagators")),
            ]),
            SatelliteSimLab.AssistantMessage("可用传播器已经列出。", SatelliteSimLab.ToolCall[]),
        ])
        agent = SatelliteSimLab.SimAgent(provider; session_id = session_id)
        reply = SatelliteSimLab.run_agent(agent, "列出传播器")

        @test reply == "可用传播器已经列出。"
        @test any(m -> get(m, "role", "") == "tool", agent.messages)
        @test provider.cursor == 3
    finally
        isdir(session_dir) && rm(session_dir; recursive = true, force = true)
        SatelliteSimLab.clear_hooks!()
    end
end

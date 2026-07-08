using Test
using JSON
using SatelliteSimLab

@testset "AI ledger" begin
    session_id = "test_ledger_$(rand(UInt))"
    mem = SatelliteSimLab.SessionMemory(session_id = session_id)
    session_dir = dirname(mem.transcript_path)

    try
        d1 = SatelliteSimLab.stable_digest(Dict("b" => 2, "a" => 1))
        d2 = SatelliteSimLab.stable_digest(Dict("a" => 1, "b" => 2))
        @test d1 == d2

        event = SatelliteSimLab.record_ledger_event!(mem, Dict("event_type" => "unit", "status" => "ok"))
        @test startswith(event["event_id"], "sha256:")
        @test isfile(SatelliteSimLab.ledger_path(mem))

        SatelliteSimLab.clear_hooks!()
        agent = SatelliteSimLab.SimAgent(SatelliteSimLab.LLMProvider(; key = "dummy"); session_id = session_id)
        SatelliteSimLab.execute_tool("list_available", Dict("what" => "all"), agent)
        lines = readlines(SatelliteSimLab.ledger_path(agent.memory))
        @test any(occursin("\"status\":\"succeeded\"", line) for line in lines)

        SatelliteSimLab.execute_tool("run_simulation", Dict("constellation" => "walker 24/6/1", "steps" => 101), agent)
        lines2 = readlines(SatelliteSimLab.ledger_path(agent.memory))
        @test any(occursin("\"status\":\"blocked\"", line) for line in lines2)
    finally
        isdir(session_dir) && rm(session_dir; recursive = true, force = true)
        SatelliteSimLab.clear_hooks!()
    end
end

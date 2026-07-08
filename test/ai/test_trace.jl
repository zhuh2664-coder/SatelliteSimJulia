using Test
using SatelliteSimLab

@testset "AI trace inspection" begin
    session_id = "test_trace_$(rand(UInt))"
    mem = SatelliteSimLab.SessionMemory(session_id = session_id)
    session_dir = dirname(mem.transcript_path)

    try
        SatelliteSimLab.record_ledger_event!(mem, Dict{String,Any}(
            "event_type" => "tool_call",
            "tool" => "list_available",
            "args" => Dict("what" => "all"),
            "args_hash" => "sha256:a",
            "status" => "succeeded",
        ))
        SatelliteSimLab.record_ledger_event!(mem, Dict{String,Any}(
            "event_type" => "tool_permission",
            "tool" => "run_simulation",
            "decision" => "ask",
            "args_hash" => "sha256:b",
        ))
        SatelliteSimLab.record_ledger_event!(mem, Dict{String,Any}(
            "event_type" => "tool_call",
            "tool" => "run_simulation",
            "args" => Dict("constellation" => "walker 24/6/1"),
            "args_hash" => "sha256:b",
            "status" => "blocked",
            "reason" => "human approval required",
        ))

        trace = SatelliteSimLab.load_agent_trace(mem)
        @test trace.session_id == session_id
        @test length(trace.events) == 3
        @test all(e -> e.session_id == session_id, trace.events)

        blocked = SatelliteSimLab.filter_trace(trace; event_type = "tool_call", status = "blocked")
        @test length(blocked.events) == 1
        @test blocked.events[1].payload["tool"] == "run_simulation"

        tools = SatelliteSimLab.filter_trace(trace; tool = ["list_available", "run_simulation"])
        @test length(tools.events) == 3

        timeline = SatelliteSimLab.trace_timeline(trace)
        @test length(timeline) == 3
        @test occursin("tool_call", timeline[1])
        @test occursin("status=succeeded", timeline[1])
        @test occursin("decision=ask", timeline[2])
        @test occursin("reason=human approval required", timeline[3])

        limited = SatelliteSimLab.trace_timeline(trace; max_events = 2)
        @test length(limited) == 2

        plan = SatelliteSimLab.tool_replay_plan(trace)
        @test length(plan) == 2
        @test plan[1]["tool"] == "list_available"
        @test plan[2]["status"] == "blocked"
    finally
        isdir(session_dir) && rm(session_dir; recursive = true, force = true)
    end
end

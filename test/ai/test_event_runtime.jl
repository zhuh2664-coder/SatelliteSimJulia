using Test
using Dates
using SatelliteSimLab

@testset "AI event runtime" begin
    session_id = "test_event_runtime_$(rand(UInt))"
    runtime = SatelliteSimLab.AIRuntime(session_id = session_id)
    session_dir = dirname(runtime.memory.transcript_path)

    try
        seen = String[]
        SatelliteSimLab.subscribe!(runtime, "satellite.run.started") do event, rt
            push!(seen, "exact:" * event.type)
            return SatelliteSimLab.AIEvent(
                "derived_1",
                "test_handler",
                "satellite.run.completed",
                event.subject,
                now(),
                Dict{String,Any}("ok" => true),
            )
        end
        SatelliteSimLab.subscribe!(runtime, "satellite.run.*") do event, rt
            push!(seen, "wildcard:" * event.type)
            return nothing
        end

        @test SatelliteSimLab.event_matches("satellite.run.*", "satellite.run.started")
        @test !SatelliteSimLab.event_matches("satellite.run.*", "satellite.plan.started")

        SatelliteSimLab.emit_event!(runtime;
            source = "unit",
            type = "satellite.run.started",
            subject = "run_1",
            data = Dict{String,Any}("mission" => "coverage"),
        )
        n = SatelliteSimLab.run_event_loop!(runtime)
        @test n == 2
        @test runtime.handled == 2
        @test seen == [
            "exact:satellite.run.started",
            "wildcard:satellite.run.started",
            "wildcard:satellite.run.completed",
        ]

        lines = readlines(SatelliteSimLab.ledger_path(runtime.memory))
        @test any(occursin("ai_runtime_event_published", line) for line in lines)
        @test any(occursin("ai_runtime_event_handled", line) for line in lines)

        SatelliteSimLab.emit_event!(runtime;
            source = "unit",
            type = "satellite.run.started",
            subject = "run_2",
            data = Dict{String,Any}(),
        )
        state = SatelliteSimLab.runtime_state(runtime)
        @test state["handled"] == 2
        @test length(state["queue"]) == 1
        @test state["subscriptions"] == ["satellite.run.*", "satellite.run.started"]

        restored = SatelliteSimLab.AIRuntime(session_id = session_id * "_restored")
        SatelliteSimLab.load_runtime_state!(restored, state)
        @test restored.handled == 2
        @test length(restored.queue) == 1
        @test restored.queue[1].subject == "run_2"
    finally
        isdir(session_dir) && rm(session_dir; recursive = true, force = true)
        restored_dir = joinpath("data", "sessions", session_id * "_restored")
        isdir(restored_dir) && rm(restored_dir; recursive = true, force = true)
        SatelliteSimLab.clear_hooks!()
    end
end

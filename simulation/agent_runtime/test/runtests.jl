using SatelliteSimAgentRuntime
using Test

@testset "SatelliteSimAgentRuntime" begin
    @test AgentConfig(sat_id = 1) isa AgentConfig
    @test SatelliteAgentState(id = 1) isa SatelliteAgentState

    agent = SimpleAgent(
        config = AgentConfig(sat_id = 1),
        state = SatelliteAgentState(id = 1),
    )
    @test agent isa SimpleAgent
    @test SatelliteSimAgentRuntime.should_think(agent)

    event = LinkChange(0.0, 2, :up, 15.0, 100.0)
    SatelliteSimAgentRuntime.process_event!(agent, event)
    @test length(agent.memory.recent_events) == 1

    SatelliteSimAgentRuntime.step!(agent, 1.0)
    @test 0.0 <= agent.state.power_level <= 1.0

    runtime = AgentRuntime(agent = agent, dt = 0.0)
    SatelliteSimAgentRuntime.push_event!(runtime, BundleArrival(0.0, 2, UInt8[0x01], 1))
    runtime(; timeout_s = 0.0)
    @test runtime.tick >= 100
    @test length(agent.memory.recent_events) >= 1

    mission = Mission(
        id = "m1",
        priority = 1,
        mission_type = :sense,
        flops = 1.0,
        data_mb = 1.0,
        deadline_s = 10.0,
        source_id = 1,
        target_id = 0,
    )
    @test mission isa Mission
    @test Goal(description = "保持网络连通率") isa Goal
end

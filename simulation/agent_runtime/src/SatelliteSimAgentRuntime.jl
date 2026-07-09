module SatelliteSimAgentRuntime

export
    SatelliteAgentState,
    AbstractAgent,
    AgentConfig,
    SimpleAgent,
    SatelliteEvent,
    LinkChange,
    BundleArrival,
    OrbitUpdate,
    MissionArrival,
    MemoryStore,
    Goal,
    Mission,
    Task,
    AgentRuntime

using DataStructures: CircularBuffer
using Statistics

abstract type SatelliteEvent end

include("planner.jl")
include("memory.jl")
include("scheduler.jl")
include("event_loop.jl")

@kwdef mutable struct AgentRuntime{T<:AbstractAgent}
    agent::T
    dt::Float64 = 0.1
    running::Bool = true
    tick::Int = 0
    events::CircularBuffer{SatelliteEvent} = CircularBuffer{SatelliteEvent}(10000)
    start_time::Float64 = time()
end

function (runtime::AgentRuntime)(; timeout_s::Float64 = Inf)
    start = time()
    while runtime.running
        for event in runtime.events
            process_event!(runtime.agent, event)
        end
        empty!(runtime.events)

        if should_think(runtime.agent)
            think!(runtime.agent)
        end

        step!(runtime.agent, runtime.dt)
        remember!(runtime.agent)
        runtime.tick += 1

        runtime.tick % 100 == 0 && (time() - start) > timeout_s && break
        sleep(runtime.dt)
    end
end

function push_event!(rt::AgentRuntime, event::SatelliteEvent)
    push!(rt.events, event)
    nothing
end

loop(runtime::AgentRuntime; timeout_s=Inf) = runtime(; timeout_s)
stop!(runtime::AgentRuntime) = (runtime.running = false)

end # module

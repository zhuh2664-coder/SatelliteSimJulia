module SatelliteSimAgentRuntime

export
    # 核心类型
    SatelliteAgentState,
    AbstractAgent,
    AgentConfig,
    SimpleAgent,
    # 事件系统
    SatelliteEvent,
    LinkChange,
    BundleArrival,
    OrbitUpdate,
    MissionArrival,
    # 记忆系统
    MemoryStore,
    # 规划系统
    Goal,
    Mission,
    Task,
    # 运行器
    AgentRuntime

using DataStructures: CircularBuffer
using Statistics

abstract type SatelliteEvent end

include("planner.jl")
include("memory.jl")
include("scheduler.jl")
include("event_loop.jl")

"""
    AgentRuntime

创建并运行一个卫星 Agent 的主循环。

# 用法
```julia
runtime = AgentRuntime(agent, 0.1)  # 100ms 步长
runtime.loop(timeout_s=3600)         # 运行 1 小时
```
"""
@kwdef mutable struct AgentRuntime{T<:AbstractAgent}
    agent::T
    dt::Float64 = 0.1          # 主循环步长（秒）
    running::Bool = true
    tick::Int = 0
    events::CircularBuffer{SatelliteEvent} = CircularBuffer{SatelliteEvent}(10000)
    start_time::Float64 = time()
end

function (runtime::AgentRuntime)(; timeout_s::Float64 = Inf)
    start = time()
    while runtime.running
        # 1. 感知
        for event in runtime.events
            process_event!(runtime.agent, event)
        end
        empty!(runtime.events)

        # 2. 思考（是否需要 LLM？）
        if should_think(runtime.agent)
            think!(runtime.agent)
        end

        # 3. 行动
        step!(runtime.agent, runtime.dt)

        # 4. 记忆
        remember!(runtime.agent)

        runtime.tick += 1

        # 超时检查
        runtime.tick % 100 == 0 && (time() - start) > timeout_s && break
        sleep(runtime.dt)
    end
end

function push_event!(rt::AgentRuntime, event::SatelliteEvent)
    push!(rt.events, event)
    nothing
end

# 快捷别名
loop(runtime::AgentRuntime; timeout_s=Inf) = runtime(; timeout_s)
stop!(runtime::AgentRuntime) = (runtime.running = false)

end # module

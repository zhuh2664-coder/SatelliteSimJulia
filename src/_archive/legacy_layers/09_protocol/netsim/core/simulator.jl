using ConcurrentSim: Simulation, now, run, timeout, schedule, EmptySchedule, @process, @resumable
using ResumableFunctions

const _sim_env = Ref{Union{Simulation, Nothing}}(nothing)
const _stop_time = Ref(Inf)
const _is_running = Ref(false)

"""
    Initialize()
初始化仿真引擎。
"""
function Initialize()
    _sim_env[] = Simulation(0.0)
    _stop_time[] = Inf
    _is_running[] = false
    nothing
end

"""
    Now() → Float64
当前仿真时间（秒）。
"""
Now() = now(_sim_env[])

"""
    Schedule(delay, func, args...)
在 delay 秒后执行 func(args...)
"""
@resumable function _schedule_task(env::Simulation, delay::Float64, func::Function, args::Tuple)
    @yield timeout(env, delay)
    func(args...)
end

function Schedule(delay, func::Function, args...)
    e = _sim_env[]
    e === nothing && error("Simulator not initialized. Call Initialize() first.")
    @process _schedule_task(e, delay, func, args)
    nothing
end
Schedule(delay::Time, func::Function, args...) = Schedule(delay.val, func, args...)

"""
    Run(stop_time=Inf)
运行仿真。
"""
function Run(stop_time=Inf)
    e = _sim_env[]
    e === nothing && error("Simulator not initialized")
    _is_running[] = true
    try
        run(e, stop_time)
    catch ex
        if ex isa EmptySchedule
            # 正常结束
        else
            rethrow(ex)
        end
    end
    _is_running[] = false
    nothing
end

"""
    Stop(time)
设置停止时间。
"""
function Stop(time)
    _stop_time[] = time
    nothing
end
Stop(time::Time) = Stop(time.val)

"""
    Reset()
"""
function Reset()
    _sim_env[] = nothing
    _stop_time[] = Inf
    _is_running[] = false
    nothing
end

IsRunning() = _is_running[]
GetEnv() = _sim_env[]

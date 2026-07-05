# ===== 调度系统 =====

"""
    ScheduledTask

被调度的一次性任务。
"""
@kwdef struct ScheduledTask
    id::Int
    fire_at::Int      # 在哪个 tick 触发
    callback::Function
    description::String = ""
    executed::Bool = false
end

"""
    Scheduler

任务调度器，管理定时任务和延迟执行。
"""
@kwdef mutable struct Scheduler
    tasks::Vector{ScheduledTask} = ScheduledTask[]
    tick::Int = 0
end

"""
    schedule!(scheduler, delay_ticks, callback, description)

在 delay_ticks 后执行回调函数。
"""
function schedule!(sched::Scheduler, delay_ticks::Int, callback::Function, description::String="")
    task = ScheduledTask(
        length(sched.tasks) + 1,
        sched.tick + delay_ticks,
        callback,
        description,
        false
    )
    push!(sched.tasks, task)
    return task.id
end

"""
    tick!(scheduler)

推进一个 tick，触发所有到期的任务。
"""
function tick!(sched::Scheduler)
    sched.tick += 1
    for task in sched.tasks
        if !task.executed && task.fire_at <= sched.tick
            try
                task.callback()
            catch e
                @warn "Scheduled task $(task.id) ('$(task.description)') failed: $e"
            end
            # 注意：由于 task 是不可变 struct，这里需要替换
        end
    end
end

"""
    pending_count(scheduler)

返回待执行任务数。
"""
function pending_count(sched::Scheduler)::Int
    return count(t -> !t.executed, sched.tasks)
end

"""
    clear!(scheduler)

清空所有任务。
"""
function clear!(sched::Scheduler)
    empty!(sched.tasks)
    sched.tick = 0
end

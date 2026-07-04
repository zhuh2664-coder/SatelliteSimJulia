# ===== Propagate 命令（GMAT 核心命令）=====
#
# Propagate: 用 PropSetup 传播航天器一段时间。
# GMAT 脚本: PropagateEarth(sc, sc) {sc.ElapsedTime = 3600};

export PropagateCommand, execute

"""
    PropagateCommand

传播命令：用 PropSetup 传播一段时间。

# 字段
- `duration_s::Float64`: 传播时长（秒）
- `step_s::Float64`: 保存步长（秒，默认 60）
"""
Base.@kwdef struct PropagateCommand <: AbstractCommand
    duration_s::Float64 = 3600.0
    step_s::Float64 = 60.0
end

function execute(cmd::PropagateCommand, state::MissionState, setup::PropSetup)
    t0 = state.elapsed_s
    t_end = t0 + cmd.duration_s
    tspan = collect(t0:cmd.step_s:t_end)
    if isempty(tspan) || last(tspan) < t_end
        push!(tspan, t_end)
    end

    sol = propagate(setup, state.state, tspan; saveat=tspan)

    # 取最后一个状态作为新状态
    new_state = copy(sol.u[end])
    new_elapsed = sol.t[end]

    # 追加轨迹（跳过第一个点，因为它和上一个命令的终点重合）
    for k in 2:length(sol.t)
        push!(state.trajectory, copy(sol.u[k]))
        push!(state.times, sol.t[k])
    end

    state.state = new_state
    state.elapsed_s = new_elapsed
    return state
end

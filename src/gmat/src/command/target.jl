# ===== Target/Achieve 命令（GMAT 微分修正求解）=====
#
# GMAT 的 Target 命令：迭代调整变量，直到 Achieve 条件满足。
# 这是微分修正（Differential Correction）——GMAT solver 的核心。
#
# 用法：
#   Target(vary=[:dv_x], achieve=Achieve(:apoapsis_km, 800.0, 1.0),
#          commands=[PropagateCommand(3600)], setup=setup, state0=...)
# 求解器调整 :dv_x 使 1 小时后远地点 = 800km

export Achieve, Target, execute, evaluate_objective

"""
    Achieve

目标条件：某变量达到目标值（容差内）。

# 字段
- `variable::Symbol`: 待约束的变量（如 :apoapsis_km, :periapsis_km, :velocity_kms）
- `target_value::Float64`: 目标值
- `tolerance::Float64`: 容差
"""
Base.@kwdef struct Achieve
    variable::Symbol
    target_value::Float64
    tolerance::Float64 = 1.0
end

"""
    Target

微分修正命令：迭代调整 vary 变量（通过 Maneuver 的 ΔV），直到 achieve 满足。

# 字段
- `vary::Vector{Symbol}`: 待调变量（当前支持 :dv_x, :dv_y, :dv_z）
- `achieve::Achieve`: 目标条件
- `sub_commands::Vector{AbstractCommand}`: 子命令序列（在每次迭代中执行）
- `max_iter::Int`: 最大迭代次数
- `step_size::Float64`: 有限差分步长（用于估计梯度）
"""
Base.@kwdef struct Target <: AbstractCommand
    vary::Vector{Symbol} = [:dv_x]
    achieve::Achieve = Achieve(:apoapsis_km, 800.0)
    sub_commands::Vector{AbstractCommand} = PropagateCommand[]
    max_iter::Int = 20
    step_size::Float64 = 1.0   # m/s（ΔV 的有限差分步长）
end

"""
    evaluate_objective(state::MissionState, var::Symbol) -> Float64

从任务状态提取目标变量值（用于 Achieve 判据）。
"""
function evaluate_objective(state::MissionState, var::Symbol)
    r = SVector(state.state[1], state.state[2], state.state[3])
    v = SVector(state.state[4], state.state[5], state.state[6])
    r_mag = norm(r)
    v_mag = norm(v)
    # 轨道根数（二体）
    mu = 3.986004415e14  # m³/s²
    energy = v_mag^2 / 2 - mu / r_mag
    a = -mu / (2 * energy)  # 半长轴
    h = norm(cross(r, v))
    e = sqrt(max(1 - h^2 / (mu * a), 0.0))  # 偏心率
    apoapsis = a * (1 + e)     # 远地点（m）
    periapsis = a * (1 - e)    # 近地点（m）

    if var == :apoapsis_km
        return apoapsis / 1000
    elseif var == :periapsis_km
        return periapsis / 1000
    elseif var == :semi_major_km
        return a / 1000
    elseif var == :eccentricity
        return e
    elseif var == :velocity_kms
        return v_mag / 1000
    else
        error("未知目标变量: $var")
    end
end

"""
    execute(target::Target, state::MissionState, setup::PropSetup) -> MissionState

微分修正：迭代调整 ΔV 使 achieve 满足。
单变量（vary[1]）的有限差分梯度下降。
"""
function execute(target::Target, state::MissionState, setup::PropSetup)
    var = target.vary[1]
    ach = target.achieve
    dv0 = Dict(:dv_x => 0.0, :dv_y => 0.0, :dv_z => 0.0)

    best_dv = 0.0
    best_err = Inf

    for iter in 1:target.max_iter
        # 用当前 best_dv 执行子命令序列
        test_state = MissionState(state=copy(state.state), elapsed_s=state.elapsed_s,
                                   trajectory=Vector{Vector{Float64}}(), times=Float64[])
        # 在子命令前插入一个 Maneuver（当前 ΔV 猜测）
        maneuver = Maneuver(_dv_vector(var, best_dv))
        test_state2 = execute(maneuver, test_state, setup)
        for cmd in target.sub_commands
            test_state2 = execute(cmd, test_state2, setup)
        end

        # 评估目标
        val = evaluate_objective(test_state2, ach.variable)
        err = val - ach.target_value

        if abs(err) < ach.tolerance
            # 收敛：应用最佳 ΔV 到真实状态
            real_maneuver = Maneuver(_dv_vector(var, best_dv))
            state = execute(real_maneuver, state, setup)
            for cmd in target.sub_commands
                state = execute(cmd, state, setup)
            end
            return state
        end

        # 有限差分估计梯度：Δ(err)/Δ(dv)
        test_dv = best_dv + target.step_size
        test_state_p = MissionState(state=copy(state.state), elapsed_s=state.elapsed_s,
                                     trajectory=Vector{Vector{Float64}}(), times=Float64[])
        execute(Maneuver(_dv_vector(var, test_dv)), test_state_p, setup)
        for cmd in target.sub_commands
            execute(cmd, test_state_p, setup)
        end
        val_p = evaluate_objective(test_state_p, ach.variable)
        err_p = val_p - ach.target_value
        grad = (err_p - err) / target.step_size

        # 梯度下降更新
        if abs(grad) > 1e-12
            best_dv -= err / grad
        end
    end

    # 未收敛：应用最后的最佳猜测
    real_maneuver = Maneuver(_dv_vector(var, best_dv))
    state = execute(real_maneuver, state, setup)
    for cmd in target.sub_commands
        state = execute(cmd, state, setup)
    end
    return state
end

# vary 变量名 → ΔV 向量
function _dv_vector(var::Symbol, mag::Float64)
    if var == :dv_x
        return SVector(mag, 0.0, 0.0)
    elseif var == :dv_y
        return SVector(0.0, mag, 0.0)
    elseif var == :dv_z
        return SVector(0.0, 0.0, mag)
    else
        error("未知 vary 变量: $var（应为 :dv_x/:dv_y/:dv_z）")
    end
end

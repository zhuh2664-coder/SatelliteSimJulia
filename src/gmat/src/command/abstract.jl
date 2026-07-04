# ===== 任务序列命令抽象层（GMAT Command/MissionSequence）=====
#
# GMAT 的核心范式：用命令序列描述任务（Propagate → Maneuver → Target）。
# 每个命令在航天器状态上执行，产出新状态。
# 这是声明式任务设计——和 SatelliteSimJulia 的意图层思想呼应。

export AbstractCommand, MissionState, execute, run_mission

"""
    MissionState

任务执行状态：航天器当前状态（位置+速度）+ 当前时间。
命令序列在此状态上顺序执行。
"""
Base.@kwdef mutable struct MissionState
    state::Vector{Float64}     # [x,y,z,vx,vy,vz]（m, m/s, ECI）
    elapsed_s::Float64         # 从历元起的累计时间（s）
    trajectory::Vector{Vector{Float64}}  # 轨迹历史（每个传播点）
    times::Vector{Float64}     # 对应时间点
end

"""命令抽象类型。每个子类型实现 execute(cmd, state, setup) -> 新状态。"""
abstract type AbstractCommand end

"""
    execute(cmd::AbstractCommand, state::MissionState, setup::PropSetup) -> MissionState

执行单个命令，返回更新后的状态。子类型必须实现。
"""
function execute end

"""
    run_mission(commands::Vector{AbstractCommand}, setup::PropSetup, state0::Vector{Float64}) -> MissionState

执行任务序列：顺序应用每个命令。
"""
function run_mission(commands::Vector{AbstractCommand}, setup::PropSetup, state0::Vector{Float64})
    state = MissionState(state=copy(state0), elapsed_s=0.0,
                         trajectory=[copy(state0)], times=[0.0])
    for cmd in commands
        state = execute(cmd, state, setup)
    end
    return state
end

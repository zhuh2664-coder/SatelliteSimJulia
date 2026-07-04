# ===== Maneuver 命令（GMAT 机动命令）=====
#
# 脉冲机动（瞬时速度增量 ΔV）：GMAT 的 BeginFiniteBurn/Maneuver 简化版。
# 脉冲机动：瞬时改变速度，位置不变。

export Maneuver, execute

"""
    Maneuver

脉冲机动命令：瞬时速度增量 ΔV（ECI 系，m/s）。

# 字段
- `delta_v::SVector{3}`: 速度增量（m/s，ECI）
"""
struct Maneuver <: AbstractCommand
    delta_v::SVector{3,Float64}
end

Maneuver(dvx::Real, dvy::Real, dvz::Real) = Maneuver(SVector(Float64(dvx), Float64(dvy), Float64(dvz)))

function execute(cmd::Maneuver, state::MissionState, setup::PropSetup)
    # 脉冲机动：速度 += ΔV，位置/时间不变
    new_state = copy(state.state)
    new_state[4] += cmd.delta_v[1]
    new_state[5] += cmd.delta_v[2]
    new_state[6] += cmd.delta_v[3]
    state.state = new_state
    # 机动不产生新轨迹点（瞬时）
    return state
end

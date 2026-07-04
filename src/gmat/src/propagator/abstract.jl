# ===== 积分器抽象层（GMAT Integrator/PropSetup）=====
#
# GMAT 的 PropSetup = ForceModel + Integrator + Spacecraft 组合。
# 积分器用 OrdinaryDiffEq 后端（Julia 生态最成熟的 ODE 套件）。

export AbstractIntegrator, integrate

"""积分器抽象类型。子类型封装 OrdinaryDiffEq 的具体算法。"""
abstract type AbstractIntegrator end

"""
    integrate(setup::PropSetup, state0::AbstractVector, tspan) -> 解

用 PropSetup 的积分器+力模型传播状态。
state0 = [x, y, z, vx, vy, vz]（ECI，m，m/s）
返回 ODE 解（可直接索引 sol.t, sol.u）。
"""
function integrate end

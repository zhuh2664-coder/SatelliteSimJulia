# ===== PropSetup：力模型 + 积分器 + 航天器 的组合（GMAT 核心概念）=====
#
# GMAT 的 PropSetup 是航天动力学核心抽象：把"怎么算力"和"怎么积分"组合。
# propagate(setup, state0, tspan) → 轨迹

using OrdinaryDiffEq

export PropSetup, propagate

"""
    PropSetup

GMAT 的传播配置：力模型 + 积分器 + 航天器 的组合。

这是航天动力学的核心抽象——同一个航天器可以用不同力模型+不同积分器传播。
"""
Base.@kwdef struct PropSetup
    force_model::ForceModel
    integrator::AbstractIntegrator = PrinceDormand78()
    spacecraft::Spacecraft = Spacecraft()
end

"""
    propagate(setup::PropSetup, state0::AbstractVector, tspan; saveat=tspan) -> ODE 解

用 PropSetup 传播航天器状态。

# 参数
- `setup`: 传播配置（力模型+积分器+航天器）
- `state0`: 初始状态 [x,y,z,vx,vy,vz]（ECI，m，m/s）
- `tspan`: 时间向量（s，如 collect(0:60:86400)）
- `saveat`: 保存点（默认 = tspan）

# 返回
OrdinaryDiffEq 解对象。sol.t = 时间，sol.u[k] = 第 k 个时刻的 [x,y,z,vx,vy,vz]。
"""
function propagate(setup::PropSetup, state0::AbstractVector, tspan; saveat=nothing)
    fm = setup.force_model
    sc = setup.spacecraft
    integ = setup.integrator

    # ODE 右端：du/dt = f(u, t)
    # u = [x,y,z,vx,vy,vz]
    # du[1:3] = v（速度）
    # du[4:6] = 加速度（力模型）
    function ode!(du, u, p, t)
        r = SVector(u[1], u[2], u[3])
        v = SVector(u[4], u[5], u[6])
        a = acceleration(fm, r, v, t, sc)
        du[1], du[2], du[3] = u[4], u[5], u[6]
        du[4], du[5], du[6] = a[1], a[2], a[3]
    end

    t_start = first(tspan)
    t_end = last(tspan)
    prob = ODEProblem(ode!, state0, (t_start, t_end))
    save_points = saveat === nothing ? tspan : saveat

    sol = solve(prob, _alg(integ);
                reltol=integ.reltol, abstol=integ.abstol,
                saveat=save_points)
    return sol
end

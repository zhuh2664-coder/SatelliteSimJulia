# ===== PrinceDormand78 积分器（GMAT 默认高精度，8(7) 阶）=====
#
# 对应 GMAT 的 PrinceDormand78 / DormandPrince。
# 用 OrdinaryDiffEq 的 DP8（Dormand-Prince 8(5,3)，8 阶）实现。

using OrdinaryDiffEq

export PrinceDormand78, RungeKutta89

"""
    PrinceDormand78

8(7) 阶 Prince-Dormand 积分器（GMAT 默认高精度传播器）。
基于 OrdinaryDiffEq 的 DP8。
"""
Base.@kwdef struct PrinceDormand78 <: AbstractIntegrator
    reltol::Float64 = 1e-12
    abstol::Float64 = 1e-12
end

"""
    RungeKutta89

8(9) 阶 Runge-Kutta 积分器（GMAT 高阶选项）。
基于 OrdinaryDiffEq 的 Vern9。
"""
Base.@kwdef struct RungeKutta89 <: AbstractIntegrator
    reltol::Float64 = 1e-13
    abstol::Float64 = 1e-13
end

# 选 OrdinaryDiffEq 算法（内部）
_alg(::PrinceDormand78) = DP8()
_alg(::RungeKutta89) = Vern9()

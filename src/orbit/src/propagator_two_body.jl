# ===== 轨道传播 =====
# 用 SatelliteToolbox 传播器计算卫星位置。
# 支持：二体 / J2 / J4
#
# 原则：能用官方库的绝不自己写。
#   - 传播器 → SatelliteToolbox.Propagators
#   - ECI→ECEF → SatelliteToolbox.r_eci_to_ecef()

import SatelliteToolbox
using SatelliteToolbox: KeplerianElements, OrbitStateVector
using SatelliteToolbox.Propagators: init, step!
using LinearAlgebra: norm, cross

export AbstractKeplerianPropagator, TwoBodyPropagator, J2Propagator, J4Propagator,
       resolve_keplerian_propagator, propagate_to_ecef, propagate_positions

abstract type AbstractKeplerianPropagator end
struct TwoBodyPropagator <: AbstractKeplerianPropagator end
struct J2Propagator <: AbstractKeplerianPropagator end
struct J4Propagator <: AbstractKeplerianPropagator end

resolve_keplerian_propagator(p::AbstractKeplerianPropagator) = p
resolve_keplerian_propagator(::Val{:two_body}) = TwoBodyPropagator()
resolve_keplerian_propagator(::Val{:j2}) = J2Propagator()
resolve_keplerian_propagator(::Val{:j4}) = J4Propagator()
resolve_keplerian_propagator(p::Symbol) = resolve_keplerian_propagator(Val(p))

# ----- 传播器工厂 -----

_make_propagator(el::KeplerianElements, ::TwoBodyPropagator) = init(Val(:TwoBody), el)
_make_propagator(el::KeplerianElements, ::J2Propagator) = init(Val(:J2), el)
_make_propagator(el::KeplerianElements, ::J4Propagator) = init(Val(:J4), el)

# ----- 位置计算 -----

"""
    propagate_positions(elems, tspan; propagator=:two_body) -> Array{Float64,3}

对一组 KeplerianElements 在时间点 tspan 上传播，返回惯性系位置矩阵。

# 参数
- `elems::Vector{KeplerianElements}`: 卫星轨道根数列表
- `tspan::Vector{Float64}`: 时间点 (s)
- `propagator`: `TwoBodyPropagator()`（默认）、`J2Propagator()`、`J4Propagator()`；
  兼容旧写法 `:two_body`、`:j2`、`:j4`

# 返回值
`(N_sat, N_time, 3)` 矩阵，`pos[i, j, :]` 为第 i 颗卫星第 j 个时间步的 (x, y, z) km
"""
function propagate_positions(
    elems::Vector{<:KeplerianElements},
    tspan::Vector{Float64};
    propagator=TwoBodyPropagator(),
)
    N = length(elems)
    M = length(tspan)
    pos = zeros(N, M, 3)
    propagator = resolve_keplerian_propagator(propagator)

    Threads.@threads for i in 1:N
        p = _make_propagator(elems[i], propagator)
        for j in 1:M
            Δt = j == 1 ? tspan[1] : tspan[j] - tspan[j-1]
            state = step!(p, Δt, OrbitStateVector)
            pos[i, j, 1] = state.r[1] / 1000  # m → km
            pos[i, j, 2] = state.r[2] / 1000
            pos[i, j, 3] = state.r[3] / 1000
        end
    end
    return pos
end

"""
    propagate_to_ecef(elems, tspan; kwargs...) -> Array{Float64,3}

传播并转 ECEF（用 SatelliteToolbox 官方 r_eci_to_ecef，含岁差章动极移修正）。
"""
function propagate_to_ecef(elems::Vector{<:KeplerianElements}, tspan::Vector{Float64};
                            propagator=TwoBodyPropagator())
    N = length(elems)
    M = length(tspan)
    pos_ecef = zeros(N, M, 3)
    propagator = resolve_keplerian_propagator(propagator)

    Threads.@threads for i in 1:N
        p = _make_propagator(elems[i], propagator)
        for j in 1:M
            Δt = j == 1 ? tspan[1] : tspan[j] - tspan[j-1]
            state = step!(p, Δt, OrbitStateVector)
            r_eci = state.r  # m, TEME 惯性系

            # ── 用官方库转换 ECI→ECEF ──
            # epcoh t=0=JD0, tspan[j] 秒后 = JD0 + tspan[j]/86400
            jd = tspan[j] / 86400.0
            D = SatelliteToolbox.r_eci_to_ecef(
                SatelliteToolbox.TEME(),
                SatelliteToolbox.PEF(),
                jd,
            )
            r_ecef = D * r_eci

            pos_ecef[i, j, 1] = r_ecef[1] / 1000  # m → km
            pos_ecef[i, j, 2] = r_ecef[2] / 1000
            pos_ecef[i, j, 3] = r_ecef[3] / 1000
        end
    end
    return pos_ecef
end

"""
    propagate_to_ecef_with_vel(elems, tspan; kwargs...) -> (pos, vel)

传播并转 ECEF，同时返回位置 (N×M×3) 和速度 (N×M×3) km/(km/s)。
速度已包含地球自转修正。
"""
function propagate_to_ecef_with_vel(elems::Vector{KeplerianElements}, tspan::Vector{Float64};
                                     propagator=TwoBodyPropagator())
    N = length(elems)
    M = length(tspan)
    pos_ecef = zeros(N, M, 3)
    vel_ecef = zeros(N, M, 3)
    propagator = resolve_keplerian_propagator(propagator)
    ω_earth = OMEGA_EARTH  # → Core/L0

    for i in 1:N
        p = _make_propagator(elems[i], propagator)
        for j in 1:M
            Δt = j == 1 ? tspan[1] : tspan[j] - tspan[j-1]
            state = step!(p, Δt, OrbitStateVector)
            r_eci, v_eci = state.r, state.v  # m, m/s, TEME

            jd = tspan[j] / 86400.0
            D = SatelliteToolbox.r_eci_to_ecef(
                SatelliteToolbox.TEME(),
                SatelliteToolbox.PEF(),
                jd,
            )
            r_ecef = D * r_eci

            # ECEF 速度 = D × v_eci - ω_earth × (D × r_eci)
            v_rot = D * v_eci
            ω = [0.0, 0.0, ω_earth]
            v_corr = cross(ω, r_ecef)
            v_ecef_rot = v_rot - v_corr

            pos_ecef[i, j, 1] = r_ecef[1] / 1000
            pos_ecef[i, j, 2] = r_ecef[2] / 1000
            pos_ecef[i, j, 3] = r_ecef[3] / 1000
            vel_ecef[i, j, 1] = v_ecef_rot[1] / 1000
            vel_ecef[i, j, 2] = v_ecef_rot[2] / 1000
            vel_ecef[i, j, 3] = v_ecef_rot[3] / 1000
        end
    end
    return pos_ecef, vel_ecef
end

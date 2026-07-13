# Golden 参考：解析 Kepler 位置传播（two-body / J2 长期项，标量实现）。
#
# 冻结自 SatelliteToolbox `:TwoBody` / `:J2` 的等价解析公式（`src/orbit` 的
# `propagate_positions` / J2 所封装），常量取 SatelliteToolbox 同值：
#   μ = 3.986004415e14 m³/s² = 3.986004415e5 km³/s²、J2 = 0.0010826261738522227、
#   R⊕ = 6378.137 km。用作 `propagate_kepler_gpu` 的对标基准。
#
# 覆盖范围：惯性系解析位置（two-body 与 J2 长期项）及显式 UT1 历元的 TEME→PEF
# GMST 位置旋转。近地 SGP4 的独立参考见 `golden_sgp4_reference.jl`。
#
# 元素约定与 `generate_walker_delta` 一致：`KeplerianElements(t0, a, e, i, Ω, ω, ν)`，
# 最后一个角为**真近点角** ν（近圆轨道 ≈ 平近点角）。

module GoldenPropagatorReference

const MU_EARTH_KM3_S2 = 3.986004415e5
const J2_EARTH = 0.0010826261738522227
const EARTH_RADIUS_KM = 6378.137

"""Newton 解 Kepler 方程 `M = E - e·sinE`（固定 20 次，与设备核一致）。"""
function kepler_solve(mean_anom::Float64, e::Float64)
    ecc_anom = mean_anom
    for _ in 1:20
        ecc_anom -= (ecc_anom - e * sin(ecc_anom) - mean_anom) /
                    (1.0 - e * cos(ecc_anom))
    end
    return ecc_anom
end

"""
单星、单时刻的解析 ECI 位置（km）。`model` ∈ (`:two_body`, `:j2`)。

`:two_body` 用 `M(t)=M₀+n₀t`；`:j2` 额外叠加升交点赤经/近地点幅角的长期漂移
与 J2 修正平均运动 n̄（a、e、i 无长期项）。
"""
function propagate_one(
    a, e, i, raan0, argp0, nu0, t;
    model=:j2,
    mu=MU_EARTH_KM3_S2,
    j2=J2_EARTH,
    earth_radius=EARTH_RADIUS_KM,
)
    sqrt_ome2 = sqrt(1.0 - e^2)
    ecc_anom0 = atan(sqrt_ome2 * sin(nu0), e + cos(nu0))
    mean_anom0 = ecc_anom0 - e * sin(ecc_anom0)
    n0 = sqrt(mu / a^3)

    nbar = n0
    d_raan = 0.0
    d_argp = 0.0
    if model === :j2
        p_semi = a * (1.0 - e^2)
        k = 1.5 * j2 * (earth_radius / p_semi)^2
        nbar = n0 * (1.0 + k * sqrt_ome2 * (1.0 - 1.5 * sin(i)^2))
        d_raan = -k * nbar * cos(i)
        d_argp = k * nbar * (2.0 - 2.5 * sin(i)^2)
    end

    mean_anom = mean_anom0 + nbar * t
    raan = raan0 + d_raan * t
    argp = argp0 + d_argp * t

    ecc_anom = kepler_solve(mean_anom, e)
    nu = atan(sqrt_ome2 * sin(ecc_anom), cos(ecc_anom) - e)
    r = a * (1.0 - e * cos(ecc_anom))
    x_pf = r * cos(nu)
    y_pf = r * sin(nu)

    cos_raan, sin_raan = cos(raan), sin(raan)
    cos_argp, sin_argp = cos(argp), sin(argp)
    cos_i, sin_i = cos(i), sin(i)
    x = x_pf * (cos_raan * cos_argp - sin_raan * sin_argp * cos_i) -
        y_pf * (cos_raan * sin_argp + sin_raan * cos_argp * cos_i)
    y = x_pf * (sin_raan * cos_argp + cos_raan * sin_argp * cos_i) -
        y_pf * (sin_raan * sin_argp - cos_raan * cos_argp * cos_i)
    z = x_pf * (sin_argp * sin_i) + y_pf * (cos_argp * sin_i)
    return (x, y, z)
end

"""
批量 `(N, T, 3)` 解析 ECI 位置（km）。元素向量长度 N，`tspan` 长度 T。
与 `propagate_kepler_gpu` 的输出布局对齐（satellite, time, xyz）。
"""
function propagate_series(sma_km, ecc, inc, raan, argp, nu, tspan; kwargs...)
    n_sat = length(sma_km)
    n_times = length(tspan)
    positions = Array{Float64}(undef, n_sat, n_times, 3)
    for s in 1:n_sat
        for (time_index, t) in enumerate(tspan)
            x, y, z = propagate_one(
                sma_km[s], ecc[s], inc[s], raan[s], argp[s], nu[s], t; kwargs...,
            )
            positions[s, time_index, 1] = x
            positions[s, time_index, 2] = y
            positions[s, time_index, 3] = z
        end
    end
    return positions
end

# ── TEME → PEF 位置：恒星时 Z 旋转 ───────────────────────────────────────────
# 复刻 SatelliteToolboxBase.jd_to_gmst（Vallado GMST1982）；不含极移，不是 ITRF。

const JD_J2000 = 2451545.0

"""Vallado GMST1982（rad）；`jd_ut1` 为 UT1 儒略日。复刻 `SatelliteToolboxBase.jd_to_gmst`。"""
function gmst_rad(jd_ut1)
    t = (jd_ut1 - JD_J2000) / 36525.0
    sec = muladd(
        t,
        muladd(t, muladd(t, -6.2e-6, 0.093104), 876600.0 * 3600.0 + 8640184.812866),
        67310.54841,
    )
    sec = mod(sec, 86400.0)
    return sec * (π / 43200.0)
end

"""单星、单时刻的解析 PEF 位置（km）；`jd = epoch_jd_ut1 + t/86400`。"""
function propagate_one_pef(
    a, e, i, raan0, argp0, nu0, t;
    epoch_jd_ut1,
    kwargs...,
)
    x, y, z = propagate_one(a, e, i, raan0, argp0, nu0, t; kwargs...)
    theta = gmst_rad(epoch_jd_ut1 + t / 86400.0)
    c, s = cos(theta), sin(theta)
    return (c * x + s * y, -s * x + c * y, z)
end

"""批量 `(N, T, 3)` 解析 PEF 位置（km）。与 `propagate_to_pef_gpu` 输出布局对齐。"""
function propagate_series_pef(
    sma_km, ecc, inc, raan, argp, nu, tspan;
    epoch_jd_ut1,
    kwargs...,
)
    n_sat = length(sma_km)
    n_times = length(tspan)
    positions = Array{Float64}(undef, n_sat, n_times, 3)
    for s in 1:n_sat
        for (time_index, t) in enumerate(tspan)
            x, y, z = propagate_one_pef(
                sma_km[s], ecc[s], inc[s], raan[s], argp[s], nu[s], t;
                epoch_jd_ut1=epoch_jd_ut1,
                kwargs...,
            )
            positions[s, time_index, 1] = x
            positions[s, time_index, 2] = y
            positions[s, time_index, 3] = z
        end
    end
    return positions
end

end # module

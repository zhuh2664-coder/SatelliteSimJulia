# =============================================================================
# Layer 1 — 可微 J2 解析传播器（调研 §7.5 推荐路径）
# =============================================================================
# 在 propagator_keplerian.jl 的二体基础上，加入 J2 长期摄动项。
# J2 摄动使 RAAN(Ω)、近地点幅角(ω)、平近点角(M) 有长期漂移。
#
# 参考：Bate-Mueller-White / Vallado 教科书，J2 一阶长期摄动：
#   Ω̇ = -3/2 · J2 · n · (R/p)² · cos(i)            [RAAN 回归]
#   ω̇ =  3/4 · J2 · n · (R/p)² · (5cos²(i) - 1)    [近地点进动]
#   Ṁ =  n · (1 + 3/4 · J2 · (R/p)² · √(1-e²) · (3cos²(i) - 1))
#
# 纯 Julia 数值运算，ForwardDiff.Dual 可穿透（无分支/查找表）。
# =============================================================================

const J2 = 1.0826261732367e-3  # EGM96

"""
    j2_mean_elements(a, e, i_rad, t_sec) -> (Ω_dot, ω_dot, M_dot, n)

计算 J2 一阶长期摄动的漂移率。ForwardDiff 透明。

返回 (Ω_dot, ω_dot, M_dot) —— RAAN/近地点/平近点角的漂移率（rad/s），
以及 n —— 平均运动率（rad/s）。
"""
function j2_mean_elements(a::T, e::T, i_rad::T, t_sec::T) where T<:Real
    μ = T(MU_KM3_S2)
    R = T(R_EARTH_KM)
    n = sqrt(μ / a^3)                    # 平均运动
    p = a * (one(T) - e^2)              # 半通径
    ratio = R / p
    factor = T(1.5) * T(J2) * n * ratio^2  # 共同因子

    ci = cos(i_rad)

    Ω_dot = -factor * ci
    ω_dot = factor * (T(2.5) * ci^2 - T(0.5))  # = 3/4 · (5cos²i - 1) · factor_ratio
    M_correction = factor * sqrt(one(T) - e^2) * (T(1.5) * ci^2 - T(0.5))
    M_dot = n + M_correction

    return Ω_dot, ω_dot, M_dot, n
end

"""
    satellite_ecef_j2(raan_rad, ma_rad, inc_rad, alt_km, t_sec; e=0.001) -> (x, y, z)

可微 J2 解析传播器：二体 + J2 长期摄动（Ω̇/ω̇/Ṁ）。

与 propagator_keplerian.jl 的 satellite_ecef 相比，本函数考虑了 J2 摄动导致的
轨道根数长期演化，物理精度更高（调研 §7.1: J2 1天误差 ~几km vs 二体 ~100s km）。

ForwardDiff 友好：无分支、无查找表，所有运算对 Dual 数透明。
raan_rad/ma_rad 可以是 ForwardDiff.Dual，其余参数为 Float64。
"""
function satellite_ecef_j2(raan_rad::TR, ma_rad::TR, inc_rad::TI, alt_km::TA, t_sec::TT;
                            e=0.001) where {TR<:Number, TI<:Number, TA<:Number, TT<:Number}
    # 提升所有到 raan_rad 的类型（Dual 传播）
    T = TR
    a = T(R_EARTH_KM) + T(alt_km)
    e_T = T(e)
    inc_T = T(inc_rad)
    t_T = T(t_sec)

    # J2 长期摄动漂移率
    Ω_dot, ω_dot, M_dot, n = j2_mean_elements(a, e_T, inc_T, t_T)

    # 漂移后的轨道根数
    Ω_t = raan_rad + Ω_dot * t_T
    ω_t = T(0.0) + ω_dot * t_T       # 近地点幅角（圆轨道近似 ω₀=0）
    M_t = ma_rad + M_dot * t_T

    θ = M_t + ω_t                       # 真近点角 ≈ 平近点角 + 近地点幅角（圆轨近似）

    # Perifocal → ECI（含 J2 漂移后的 Ω, i）
    x_orb = a * cos(θ)
    y_orb = a * sin(θ)

    ci, si = cos(inc_T), sin(inc_T)
    cΩ, sΩ = cos(Ω_t), sin(Ω_t)

    x_eci = cΩ * x_orb - sΩ * ci * y_orb
    y_eci = sΩ * x_orb + cΩ * ci * y_orb
    z_eci = si * y_orb

    # ECI → ECEF
    gmst = T(OMEGA_EARTH) * t_T
    cg, sg = cos(gmst), sin(gmst)

    x_ecef =  cg * x_eci + sg * y_eci
    y_ecef = -sg * x_eci + cg * y_eci
    z_ecef =  z_eci

    return x_ecef, y_ecef, z_ecef
end

"""
    constellation_positions_j2(params, alt_km, inc_rad, t_sec) -> Matrix{T}

批量可微 J2 传播：N 颗卫星的 (raan, ma) 参数向量 → N×3 ECEF 位置矩阵。

params: [raan_1, raan_2, ..., raan_P, ma_1, ma_2, ..., ma_N]（平铺向量）
ForwardDiff.gradient 可对此函数求导，实现轨道参数梯度优化。
"""
function constellation_positions_j2(params::AbstractVector{T}, alt_km, inc_rad, t_sec) where T <: Number
    n_sats = length(params) ÷ 2
    raans = params[1:n_sats]
    mas = params[n_sats+1:end]
    pos = Matrix{T}(undef, n_sats, 3)
    for i in 1:n_sats
        pos[i, 1], pos[i, 2], pos[i, 3] = satellite_ecef_j2(raans[i], mas[i], inc_rad, alt_km, t_sec; e=0.001)
    end
    return pos
end

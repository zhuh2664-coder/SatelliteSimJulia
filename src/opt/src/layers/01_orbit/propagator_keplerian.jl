# =============================================================================
# Layer 1 — Orbit Propagation (Analytical Keplerian)
# =============================================================================
# 来源: DifferentiableLEO/src/orbit/keplerian.jl
# 提供 Enzyme 原生可微的 Keplerian 解析传播器。
# 与主项目的 SGP4/TwoBody/J2/J4 传播器互补：本传播器牺牲精度换速度 (28ms/步)。
#
# 模块内常量（不与 SatelliteSimJulia 冲突，因为处于独立子模块命名空间）：
#   MU_KM3_S2, R_EARTH_KM, OMEGA_EARTH
# =============================================================================

const MU_KM3_S2  = SatelliteSimCore.MU_KM3_S2      # → Core/L0
const R_EARTH_KM = SatelliteSimCore.WGS84_EQUATORIAL_RADIUS_KM  # → Core/L0
const OMEGA_EARTH = SatelliteSimCore.OMEGA_EARTH          # → Core/L0

"""
    satellite_ecef(raan_rad, ma_rad, inc_rad, alt_km, t_sec) -> (x, y, z)

Propagate a single satellite from orbital elements to ECEF at time t_sec.

Arguments:
- raan_rad : right ascension of ascending node (rad)
- ma_rad   : mean anomaly at epoch (rad)
- inc_rad  : inclination (rad)
- alt_km   : altitude (km)
- t_sec    : propagation time from epoch (seconds)

Returns ECEF position (km). Differentiable w.r.t. all orbital parameters.
"""
function satellite_ecef(raan_rad::T, ma_rad::T, inc_rad::T, alt_km::T, t_sec::T) where T <: Number
    a   = T(R_EARTH_KM) + alt_km
    n   = sqrt(T(MU_KM3_S2) / a^3)        # mean motion (rad/s)
    M   = ma_rad + n * t_sec               # mean anomaly at t
    θ   = M                                # true anomaly = mean anomaly (circular orbit)

    # Perifocal frame position
    x_orb = a * cos(θ)
    y_orb = a * sin(θ)

    # Rotate by RAAN (Ω), inclination (i): perifocal → ECI
    ci, si = cos(inc_rad),  sin(inc_rad)
    cΩ, sΩ = cos(raan_rad), sin(raan_rad)

    x_eci = cΩ * x_orb - sΩ * ci * y_orb
    y_eci = sΩ * x_orb + cΩ * ci * y_orb
    z_eci = si * y_orb

    # ECI → ECEF: rotate by Greenwich Sidereal Time (GMST ≈ OMEGA_EARTH * t)
    gmst  = T(OMEGA_EARTH) * t_sec
    cg, sg = cos(gmst), sin(gmst)

    x_ecef =  cg * x_eci + sg * y_eci
    y_ecef = -sg * x_eci + cg * y_eci
    z_ecef =  z_eci

    return x_ecef, y_ecef, z_ecef
end

"""
    teme_to_ecef_simple(pos_teme, gmst_rad) -> (x, y, z)

Simple TEME → ECEF rotation using GMST angle only.
注意：主项目 SatelliteSimJulia 导出 `teme_to_ecef` (IAU-2006 完整实现)，
本模块命名为 `teme_to_ecef_simple` 以避免冲突。
"""
function teme_to_ecef_simple(pos_teme::AbstractVector{T}, gmst_rad::T) where T <: Number
    cg, sg = cos(gmst_rad), sin(gmst_rad)
    x =  cg * pos_teme[1] + sg * pos_teme[2]
    y = -sg * pos_teme[1] + cg * pos_teme[2]
    z =  pos_teme[3]
    return x, y, z
end

"""
    constellation_positions(raans, mas, inc_rad, alt_km, t_sec) -> Matrix{T}

Compute ECEF positions for all N satellites at time t_sec.

Arguments:
- raans   : RAAN vector, length P (one per orbital plane, degrees)
- mas     : mean anomaly vector, length N (one per satellite, degrees)
- inc_rad : inclination (rad)
- alt_km  : altitude (km)
- t_sec   : propagation time (seconds)

Returns N×3 matrix of ECEF positions (km).
"""
function constellation_positions(
    raans::AbstractVector{T},    # degrees, length P
    mas::AbstractVector{T},      # degrees, length N
    inc_rad::T,
    alt_km::T,
    t_sec::T,
) where T <: Number
    N = length(mas)
    P = length(raans)
    SPP = N ÷ P

    positions = Matrix{T}(undef, N, 3)
    for p in 1:P
        Ω = raans[p] * T(π / 180)
        for s in 1:SPP
            idx = (p - 1) * SPP + s
            M₀  = mas[idx] * T(π / 180)
            x, y, z = satellite_ecef(Ω, M₀, inc_rad, alt_km, t_sec)
            positions[idx, 1] = x
            positions[idx, 2] = y
            positions[idx, 3] = z
        end
    end
    return positions   # N×3
end

"""
    walker_raans(P; Ω_total=360.0) -> Vector{Float64}

Generate uniform RAAN spacing for a Walker constellation with P planes.
"""
function walker_raans(P::Int; Ω_total::Float64 = 360.0)
    return collect(range(0.0, Ω_total - Ω_total / P; length = P))
end

"""
    walker_mas(P, SPP, F=1) -> Vector{Float64}

Generate mean anomalies for a Walker P/P*SPP/F constellation.
"""
function walker_mas(P::Int, SPP::Int, F::Int = 1)
    N = P * SPP
    mas = Vector{Float64}(undef, N)
    for p in 1:P
        offset = (p - 1) * F * 360.0 / N
        for s in 1:SPP
            mas[(p - 1) * SPP + s] = mod((s - 1) * 360.0 / SPP + offset, 360.0)
        end
    end
    return mas
end

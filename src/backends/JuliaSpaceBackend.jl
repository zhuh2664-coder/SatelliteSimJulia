"""
    JuliaSpaceBackend

生产默认后端：包装 SatelliteToolbox + SatelliteToolboxSgp4。

这是唯一允许 `import SatelliteToolbox` / `import SatelliteToolboxSgp4` 的文件
（除了 `_archive/`）。上层通过 `OrbitBackend` 接口调用，不直接接触外部类型。
"""
module JuliaSpaceBackend

using Dates
import SatelliteToolbox
import SatelliteToolboxSgp4

include("OrbitBackend.jl")
using .OrbitBackend

export JuliaSpaceOrbitBackend

# ── 后端结构体 ────────────────────────────────────────────────────────────────

"""
    JuliaSpaceOrbitBackend <: AbstractOrbitBackend

包装 SatelliteToolbox 的生产后端。
- SGP4 传播：SatelliteToolboxSgp4
- 坐标转换：SatelliteToolbox TEME/PEF/ECEF
"""
struct JuliaSpaceOrbitBackend <: AbstractOrbitBackend
    verify_checksum::Bool
end

JuliaSpaceOrbitBackend(; verify_checksum::Bool = false) =
    JuliaSpaceOrbitBackend(verify_checksum)

# 全局默认单例（惰性）
const DEFAULT = Ref{Union{Nothing,JuliaSpaceOrbitBackend}}(nothing)
function default()
    if DEFAULT[] === nothing
        DEFAULT[] = JuliaSpaceOrbitBackend()
    end
    return DEFAULT[]
end

# ── 内部辅助 ──────────────────────────────────────────────────────────────────

function _to_st_tle(tle::InternalTLE, verify_checksum::Bool)
    return SatelliteToolbox.read_tle(
        tle.line1, tle.line2;
        name = tle.name,
        verify_checksum = verify_checksum,
    )
end

function _jd(time::DateTime)::Float64
    j2000 = DateTime(2000, 1, 1, 12, 0, 0)
    return 2451545.0 + Dates.value(Dates.Millisecond(time - j2000)) / 86400_000.0
end

function _teme_to_ecef_rotation(jd::Float64)
    return SatelliteToolbox.r_eci_to_ecef(
        SatelliteToolbox.TEME(),
        SatelliteToolbox.PEF(),
        jd,
    )
end

# ── propagate_sgp4 ────────────────────────────────────────────────────────────

function OrbitBackend.propagate_sgp4(
    backend::JuliaSpaceOrbitBackend,
    tles::Vector{InternalTLE},
    time_offsets_s::Vector{<:Integer};
    epoch::DateTime,
)::Array{Float64,3}
    N = length(tles)
    T = length(time_offsets_s)
    pos_ecef = zeros(Float64, N, T, 3)

    Threads.@threads for i in 1:N
        st_tle = _to_st_tle(tles[i], backend.verify_checksum)
        sgp4d  = SatelliteToolboxSgp4.sgp4_init(st_tle)
        tle_epoch = SatelliteToolbox.tle_epoch(DateTime, st_tle)

        for j in 1:T
            target_time = epoch + Dates.Millisecond(1000 * time_offsets_s[j])
            elapsed_min = Dates.value(target_time - tle_epoch) / 60_000.0

            r_teme, _ = SatelliteToolboxSgp4.sgp4!(sgp4d, elapsed_min)

            jd = _jd(target_time)
            D  = _teme_to_ecef_rotation(jd)
            r_ecef = D * r_teme

            pos_ecef[i, j, 1] = r_ecef[1]
            pos_ecef[i, j, 2] = r_ecef[2]
            pos_ecef[i, j, 3] = r_ecef[3]
        end
    end

    return pos_ecef
end

# ── propagate_keplerian ───────────────────────────────────────────────────────
# SatelliteToolbox 没有直接的开普勒传播 API；用 SGP4 拟合（零大气阻力 bstar=0）
# 或内置 kepler_to_rv 做简单二体。这里用纯二体（GM only），后续 P3 可换成 J2。

const GM_EARTH = 3.986004418e14  # m³/s²
const R_EARTH  = 6378137.0       # m

function _kepler_mean_anomaly(M0_rad::Float64, n_rad_s::Float64, dt_s::Float64)::Float64
    return mod(M0_rad + n_rad_s * dt_s, 2π)
end

function _eccentric_anomaly(M::Float64, e::Float64; tol=1e-10, max_iter=50)::Float64
    E = M
    for _ in 1:max_iter
        dE = (M - E + e * sin(E)) / (1 - e * cos(E))
        E += dE
        abs(dE) < tol && break
    end
    return E
end

function _keplerian_to_ecef(elem::InternalKeplerianElements, dt_s::Float64)::NTuple{3,Float64}
    a = elem.semi_major_axis_m
    e = elem.eccentricity
    i = elem.inclination_rad
    Ω = elem.raan_rad
    ω = elem.arg_perigee_rad
    n = sqrt(GM_EARTH / a^3)
    M = _kepler_mean_anomaly(elem.mean_anomaly_rad, n, dt_s)
    E = _eccentric_anomaly(M, e)

    # 轨道平面位置 (m)
    x_orb = a * (cos(E) - e)
    y_orb = a * sqrt(1 - e^2) * sin(E)

    # 旋转到 ECI（J2000 近似；无极移修正）
    cΩ, sΩ = cos(Ω), sin(Ω)
    cω, sω = cos(ω), sin(ω)
    ci, si = cos(i), sin(i)

    x = (cΩ*cω - sΩ*sω*ci)*x_orb + (-cΩ*sω - sΩ*cω*ci)*y_orb
    y = (sΩ*cω + cΩ*sω*ci)*x_orb + (-sΩ*sω + cΩ*cω*ci)*y_orb
    z = (si*sω)*x_orb + (si*cω)*y_orb

    # ECI → ECEF（简化：只做 GMST 旋转）
    # GMST ≈ GMST_epoch + ω_earth * dt
    ω_earth = 7.2921150e-5  # rad/s
    # GMST at J2000.0 ≈ 4.894961212 rad
    gmst = 4.894961212 + ω_earth * (
        Dates.value(Dates.Millisecond(elem.epoch - DateTime(2000,1,1,12,0,0))) / 1000.0 + dt_s
    )
    gmst = mod(gmst, 2π)

    x_ecef =  cos(gmst)*x + sin(gmst)*y
    y_ecef = -sin(gmst)*x + cos(gmst)*y
    z_ecef =  z

    return (x_ecef/1000.0, y_ecef/1000.0, z_ecef/1000.0)  # → km
end

function OrbitBackend.propagate_keplerian(
    backend::JuliaSpaceOrbitBackend,
    elements::Vector{InternalKeplerianElements},
    time_offsets_s::Vector{<:Integer};
    epoch::DateTime,
)::Array{Float64,3}
    N = length(elements)
    T = length(time_offsets_s)
    pos_ecef = zeros(Float64, N, T, 3)

    Threads.@threads for i in 1:N
        for j in 1:T
            dt = Float64(time_offsets_s[j]) +
                 Dates.value(Dates.Millisecond(epoch - elements[i].epoch)) / 1000.0
            p = _keplerian_to_ecef(elements[i], dt)
            pos_ecef[i, j, 1] = p[1]
            pos_ecef[i, j, 2] = p[2]
            pos_ecef[i, j, 3] = p[3]
        end
    end

    return pos_ecef
end

# ── teme_to_geodetic ──────────────────────────────────────────────────────────

function OrbitBackend.teme_to_geodetic(
    ::JuliaSpaceOrbitBackend,
    pos_teme_km::NTuple{3,Float64},
    time::DateTime,
)::NTuple{3,Float64}
    jd = _jd(time)
    D  = _teme_to_ecef_rotation(jd)
    r_ecef_m = D * collect(pos_teme_km .* 1000.0)
    lat_rad, lon_rad, alt_m = SatelliteToolbox.ecef_to_geodetic(r_ecef_m)
    return (rad2deg(lat_rad), rad2deg(lon_rad), alt_m / 1000.0)
end

# ── parse_tle_lines ───────────────────────────────────────────────────────────

function OrbitBackend.parse_tle_lines(
    backend::JuliaSpaceOrbitBackend,
    lines::Vector{String},
)::Vector{InternalTLE}
    result = InternalTLE[]
    i = 1
    while i <= length(lines)
        line = strip(lines[i])
        isempty(line) && (i += 1; continue)

        if startswith(line, "1 ") && i + 1 <= length(lines)
            name  = "UNKNOWN"
            line1 = line
            line2 = strip(lines[i+1])
            i += 2
        elseif !startswith(line, "1 ") && !startswith(line, "2 ") &&
               i + 2 <= length(lines)
            name  = line
            line1 = strip(lines[i+1])
            line2 = strip(lines[i+2])
            i += 3
        else
            i += 1
            continue
        end

        st_tle = SatelliteToolbox.read_tle(line1, line2;
            name = name,
            verify_checksum = backend.verify_checksum,
        )
        tle_epoch = SatelliteToolbox.tle_epoch(DateTime, st_tle)

        push!(result, InternalTLE(
            name,
            line1,
            line2,
            st_tle.n * 2π / 86400.0,          # rev/day → rad/s
            st_tle.e,
            st_tle.i,
            st_tle.Ω,
            st_tle.ω,
            st_tle.M,
            st_tle.bstar,
            tle_epoch,
        ))
    end
    return result
end

end # module JuliaSpaceBackend

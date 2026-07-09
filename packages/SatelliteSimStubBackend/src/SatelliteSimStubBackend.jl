"""
    SatelliteSimStubBackend

CI/离线测试后端：零 SatelliteToolbox 依赖。
"""
module SatelliteSimStubBackend

using Dates
using SatelliteSimBackends

export StubOrbitBackend

# ── 物理常量（标准库内实现，零外部依赖）─────────────────────────────────────

const GM_EARTH  = 3.986004418e14   # m³/s²
const R_EARTH   = 6378137.0        # m (WGS84 长半轴)
const E2_EARTH  = 0.00669437999014 # WGS84 第一偏心率平方
const ω_EARTH   = 7.2921150e-5     # rad/s 地球自转
const GMST_J2000 = 4.894961212     # rad  J2000 GMST

# ── 后端结构体 ────────────────────────────────────────────────────────────────

"""
    StubOrbitBackend <: AbstractOrbitBackend

零依赖测试后端。使用简化二体传播 + GMST 旋转。
"""
struct StubOrbitBackend <: AbstractOrbitBackend end

# ── 内部辅助 ──────────────────────────────────────────────────────────────────

function _seconds_since_j2000(t::DateTime)::Float64
    j2000 = DateTime(2000, 1, 1, 12, 0, 0)
    return Dates.value(Dates.Millisecond(t - j2000)) / 1000.0
end

function _gmst(t::DateTime)::Float64
    return mod(GMST_J2000 + ω_EARTH * _seconds_since_j2000(t), 2π)
end

function _eccentric_anomaly(M::Float64, e::Float64; tol=1e-10)::Float64
    E = M
    for _ in 1:50
        dE = (M - E + e * sin(E)) / (1 - e * cos(E))
        E += dE
        abs(dE) < tol && break
    end
    return E
end

function _propagate_one(
    a_m::Float64, e::Float64, i::Float64,
    Ω::Float64, ω::Float64, M0::Float64,
    epoch::DateTime, target::DateTime,
)::NTuple{3,Float64}
    dt = _seconds_since_j2000(target) - _seconds_since_j2000(epoch)
    n  = sqrt(GM_EARTH / a_m^3)
    M  = mod(M0 + n * dt, 2π)
    E  = _eccentric_anomaly(M, e)

    x_orb = a_m * (cos(E) - e)
    y_orb = a_m * sqrt(max(0.0, 1 - e^2)) * sin(E)

    cΩ, sΩ = cos(Ω), sin(Ω)
    cω, sω = cos(ω), sin(ω)
    ci, si  = cos(i), sin(i)

    # 轨道平面 → ECI
    x_eci =  (cΩ*cω - sΩ*sω*ci)*x_orb + (-cΩ*sω - sΩ*cω*ci)*y_orb
    y_eci =  (sΩ*cω + cΩ*sω*ci)*x_orb + (-sΩ*sω + cΩ*cω*ci)*y_orb
    z_eci =  (si*sω)*x_orb            + (si*cω)*y_orb

    # ECI → ECEF（GMST 旋转）
    θ = _gmst(target)
    x_ecef =  cos(θ)*x_eci + sin(θ)*y_eci
    y_ecef = -sin(θ)*x_eci + cos(θ)*y_eci
    z_ecef =  z_eci

    return (x_ecef/1000.0, y_ecef/1000.0, z_ecef/1000.0)  # → km
end

# ── propagate_sgp4 ────────────────────────────────────────────────────────────

function SatelliteSimBackends.propagate_sgp4(
    ::StubOrbitBackend,
    tles::Vector{InternalTLE},
    time_offsets_s::Vector{<:Integer};
    epoch::DateTime,
)::Array{Float64,3}
    N = length(tles)
    T = length(time_offsets_s)
    pos = zeros(Float64, N, T, 3)

    for i in 1:N
        tle = tles[i]
        # 从 TLE mean motion 反算半长轴（二体）
        a_m = (GM_EARTH / tle.mean_motion_rad_s^2)^(1/3)
        for j in 1:T
            target = epoch + Dates.Millisecond(1000 * time_offsets_s[j])
            p = _propagate_one(
                a_m, tle.eccentricity,
                tle.inclination_rad, tle.raan_rad,
                tle.arg_perigee_rad, tle.mean_anomaly_rad,
                tle.epoch, target,
            )
            pos[i, j, 1] = p[1]
            pos[i, j, 2] = p[2]
            pos[i, j, 3] = p[3]
        end
    end

    return pos
end

# ── propagate_keplerian ───────────────────────────────────────────────────────

function SatelliteSimBackends.propagate_keplerian(
    ::StubOrbitBackend,
    elements::Vector{InternalKeplerianElements},
    time_offsets_s::Vector{<:Integer};
    epoch::DateTime,
)::Array{Float64,3}
    N = length(elements)
    T = length(time_offsets_s)
    pos = zeros(Float64, N, T, 3)

    for i in 1:N
        el = elements[i]
        for j in 1:T
            target = epoch + Dates.Millisecond(1000 * time_offsets_s[j])
            p = _propagate_one(
                el.semi_major_axis_m, el.eccentricity,
                el.inclination_rad, el.raan_rad,
                el.arg_perigee_rad, el.mean_anomaly_rad,
                el.epoch, target,
            )
            pos[i, j, 1] = p[1]
            pos[i, j, 2] = p[2]
            pos[i, j, 3] = p[3]
        end
    end

    return pos
end

# ── teme_to_geodetic ──────────────────────────────────────────────────────────

function SatelliteSimBackends.teme_to_geodetic(
    ::StubOrbitBackend,
    pos_teme_km::NTuple{3,Float64},
    time::DateTime,
)::NTuple{3,Float64}
    # TEME → ECEF（GMST 旋转）
    θ = _gmst(time)
    x_km, y_km, z_km = pos_teme_km
    x_ecef =  cos(θ)*x_km + sin(θ)*y_km
    y_ecef = -sin(θ)*x_km + cos(θ)*y_km
    z_ecef =  z_km

    # ECEF → WGS84 经纬高（Bowring 迭代，3 次足够）
    x_m, y_m, z_m = x_ecef*1000, y_ecef*1000, z_ecef*1000
    lon_rad = atan(y_m, x_m)
    p = sqrt(x_m^2 + y_m^2)
    lat = atan(z_m, p * (1 - E2_EARTH))
    for _ in 1:4
        N_val = R_EARTH / sqrt(1 - E2_EARTH * sin(lat)^2)
        lat = atan(z_m + E2_EARTH * N_val * sin(lat), p)
    end
    N_val = R_EARTH / sqrt(1 - E2_EARTH * sin(lat)^2)
    alt_m = p / cos(lat) - N_val

    return (rad2deg(lat), rad2deg(lon_rad), alt_m / 1000.0)
end

# ── parse_tle_lines ───────────────────────────────────────────────────────────
# Stub 无法调用 SatelliteToolbox 解析；做最小 TLE 文本解析（行格式固定宽度）。

function _parse_tle_epoch(line1::AbstractString)::DateTime
    # 字段 19-32：epoch（2位年 + 儒略日小数）
    yy  = parse(Int, strip(line1[19:20]))
    ddd = parse(Float64, strip(line1[21:32]))
    year = yy >= 57 ? 1900 + yy : 2000 + yy
    base = DateTime(year, 1, 1)
    return base + Dates.Millisecond(round(Int64, (ddd - 1) * 86400_000))
end

function _parse_tle_float(s::String)::Float64
    # TLE 有时省略小数点，如 ".0021" 或 "00000-0"（指数格式）
    s = strip(s)
    if contains(s, '-') && !startswith(s, '-')
        # 格式如 "12345-3" = 0.12345e-3
        idx = findlast('-', s)
        mant = s[1:idx-1]
        exp  = parse(Int, s[idx:end])
        return parse(Float64, "." * replace(mant, " " => "")) * 10.0^exp
    end
    return parse(Float64, replace(s, " " => ""))
end

function SatelliteSimBackends.parse_tle_lines(
    ::StubOrbitBackend,
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
            i += 1; continue
        end

        length(line1) < 69 || length(line2) < 69 && continue

        epoch = _parse_tle_epoch(line1)

        inc_deg  = parse(Float64, strip(line2[9:16]))
        raan_deg = parse(Float64, strip(line2[18:25]))
        e        = parse(Float64, "0." * strip(line2[27:33]))
        ω_deg    = parse(Float64, strip(line2[35:42]))
        M_deg    = parse(Float64, strip(line2[44:51]))
        n_revday = parse(Float64, strip(line2[53:63]))

        push!(result, InternalTLE(
            name, line1, line2,
            n_revday * 2π / 86400.0,
            e,
            deg2rad(inc_deg),
            deg2rad(raan_deg),
            deg2rad(ω_deg),
            deg2rad(M_deg),
            0.0,
            epoch,
        ))
    end
    return result
end

end # module SatelliteSimStubBackend

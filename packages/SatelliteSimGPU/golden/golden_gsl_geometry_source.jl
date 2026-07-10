# 物理常量已迁移到 SatelliteSimFoundation（geometry_constants.jl）。
# 本文件保留几何函数（链路评估原语），常量通过 @reexport using SatelliteSimFoundation 可见。

# ===== 核心几何函数 =====
# 所有上层算法依赖本模块。
# 原则：官方库（SatelliteToolbox）有的函数一律直接用，没有的才自己写。

import SatelliteToolbox
using SatelliteToolbox: EARTH_EQUATORIAL_RADIUS
using LinearAlgebra: norm, cross, dot

export geodetic_to_ecef_km, ecef_to_geodetic_lla,
       distance_km, elevation_deg, has_los, propagation_delay_ms


# ----- 坐标转换（官方库封装）-----

"""
    geodetic_to_ecef_km(lat, lon, alt) -> (x, y, z)

WGS84 经纬高 → ECEF，单位 km。
"""
function geodetic_to_ecef_km(lat::Real, lon::Real, alt::Real)
    m = SatelliteToolbox.geodetic_to_ecef(deg2rad(lat), deg2rad(lon), alt * 1000)
    return (Float64(m[1] / 1000), Float64(m[2] / 1000), Float64(m[3] / 1000))
end

"""
    ecef_to_geodetic_lla(x, y, z) -> (lat, lon, alt)

ECEF → WGS84 经纬高，lat/lon 为度，alt 为 km。
"""
function ecef_to_geodetic_lla(x::Real, y::Real, z::Real)
    φ_rad, λ_rad, h_m = SatelliteToolbox.ecef_to_geodetic([
        Float64(x * 1000),
        Float64(y * 1000),
        Float64(z * 1000),
    ])
    return (rad2deg(φ_rad), rad2deg(λ_rad), h_m / 1000)
end

"""
    ecef_to_ned_vector(sat_ecef, gs_lat, gs_lon, gs_alt) -> (n, e, d)

将卫星 ECEF 位置转换到地面站局部 NED 坐标（北-东-地），单位 km。
仰角计算依赖此函数。
"""
function ecef_to_ned_vector(sat_ecef::NTuple{3,Real}, gs_lat::Real, gs_lon::Real, gs_alt::Real)
    ned_m = SatelliteToolbox.ecef_to_ned(
        [sat_ecef[1]*1000, sat_ecef[2]*1000, sat_ecef[3]*1000],
        deg2rad(gs_lat), deg2rad(gs_lon), gs_alt * 1000;
        translate=true
    )
    return (Float64(ned_m[1]/1000), Float64(ned_m[2]/1000), Float64(ned_m[3]/1000))
end

# ----- 距离 / 时延 / 仰角 / LOS -----

"""
    distance_km(a, b) -> Float64

ECEF 两点欧氏距离（km）。
"""
distance_km(a::NTuple{3,Real}, b::NTuple{3,Real}) = norm(Float64.(a) .- Float64.(b))

"""
    propagation_delay_ms(dist_km) -> Float64

光传播时延（ms）。
"""
propagation_delay_ms(dist_km::Real) = dist_km / SPEED_OF_LIGHT_KM_S * 1000

"""
    elevation_deg(sat_ecef, gs_lat, gs_lon, gs_alt) -> Float64

地面站处卫星仰角（度）。调用 NED 转换 + 天底角公式。
"""
# [算法说明]
# 仰角 = 90° - 天底角
# 天底角 = arccos(-NED_z / |NED|)
# NED 系中 z 轴指向地心（向下），所以天顶方向为 -z。
function elevation_deg(sat_ecef::NTuple{3,Real}, gs_lat::Real, gs_lon::Real, gs_alt::Real)
    n, e, d = ecef_to_ned_vector(sat_ecef, gs_lat, gs_lon, gs_alt)
    r = sqrt(n^2 + e^2 + d^2)
    r ≈ 0 && return 90.0
    nadir = acos(clamp(-d / r, -1.0, 1.0))
    return rad2deg(π / 2 - nadir)
end

"""
    has_los(p1, p2; earth_radius=6378.137) -> Bool

判断两点 ECEF 连线是否被地球遮挡。
"""
# [算法说明]
# 求地心到线段最近距离，如果最近点在线段上且该距离 < 地球半径 → 被遮挡。
# 公式：t = clamp(-dot(a, s) / |s|², 0, 1)，最近点 = a + t*s
# 来自 src/core/network_layer/links.jl 的实现，已现场验证。
function has_los(p1::NTuple{3,Real}, p2::NTuple{3,Real}; earth_radius::Real=WGS84_EQUATORIAL_RADIUS_KM)
    a, b = Float64.(p1), Float64.(p2)
    s = b .- a
    s_norm2 = s[1]^2 + s[2]^2 + s[3]^2
    s_norm2 ≈ 0 && return norm(a) >= earth_radius
    t = clamp(-(a[1]*s[1] + a[2]*s[2] + a[3]*s[3]) / s_norm2, 0.0, 1.0)
    closest = a .+ t .* s
    return norm(closest) >= earth_radius
end

# ═══════════════════════════════════════════════
# RTN 坐标系（径向-切向-法向）
# ═══════════════════════════════════════════════

"""
    compute_rtn_coordinates(pos, vel, target_pos) -> (r, t, n)

计算目标点在RTN坐标系中的坐标。
R: 指向地心, T: 速度方向, N: R×T
返回 (r, t, n) 分量。
"""
function compute_rtn_coordinates(pos, vel, target_pos)
    # 统一转为 Vector{Float64}（支持 Tuple 输入）
    p = collect(Float64, pos)
    v = collect(Float64, vel)
    tgt = collect(Float64, target_pos)

    # R轴：指向地心
    R = p / norm(p)

    # T轴：速度方向
    T = v / norm(v)

    # N轴：R × T（右手法则）
    N = cross(R, T)
    N = N / norm(N)

    # 计算相对位置在RTN中的坐标
    rel = tgt .- p
    r = dot(rel, R)
    t = dot(rel, T)
    n = dot(rel, N)

    return (r, t, n)
end

"""
    compute_azimuth_from_rtn(t, n) -> Float64

从RTN坐标的t,n分量计算方位角cos值。
cos_psi = n / sqrt(n² + t²)
"""
function compute_azimuth_from_rtn(t::Real, n::Real)::Float64
    denom = sqrt(n^2 + t^2)
    denom < 1e-10 && return 1.0  # 两点重合
    return n / denom
end

"""
    compute_elevation_from_rtn(r, t, n) -> Float64

从RTN坐标计算仰角（度）。
仰角 = arcsin(|r| / sqrt(r² + t² + n²))
"""
function compute_elevation_from_rtn(r::Real, t::Real, n::Real)::Float64
    dist = sqrt(r^2 + t^2 + n^2)
    dist < 1e-10 && return 90.0
    return rad2deg(asin(abs(r) / dist))
end

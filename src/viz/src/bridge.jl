# ===== 数据桥接层 =====
#
# 把 demo/lab 流程的裸数组产出适配为可视化可消费的格式。
# 同时保留旧 ConstellationEphemeris 路径的兼容。

export ecef_to_latlon, geodetic_to_xyz

# ────────────────────────────────────────────────────────────
# ECEF (x,y,z) → 地理坐标 (lat, lon, alt)
# 简化的迭代法，精度 ~1m
# ────────────────────────────────────────────────────────────

"""
    ecef_to_latlon(x, y, z; a, e²)

ECEF 笛卡尔坐标 → 地理坐标 (lat_deg, lon_deg, alt_km)。
使用 Bowring 封闭公式。
"""
function ecef_to_latlon(x, y, z;
    a = WGS84_EQUATORIAL_RADIUS_KM,
    e² = 0.006694379990141316,  # WGS84
)
    lon = atan(y, x)
    p = sqrt(x^2 + y^2)
    # Bowring 初始估计
    θ = atan(z * a, p * sqrt(1 - e²))
    lat = atan(z + e² * a * sin(θ)^3,
               p - (1 - e²) * a * cos(θ)^3)
    N = a / sqrt(1 - e² * sin(lat)^2)
    alt = (p / cos(lat)) - N  # km

    return (rad2deg(lat), rad2deg(lon), alt)
end

"""
    ecef_to_latlon_batch(positions::Matrix{Float64})

批量转换 N×3 ECEF 矩阵 → N×3 (lat, lon, alt_km) 矩阵。
"""
function ecef_to_latlon_batch(positions::Matrix{Float64})
    n = size(positions, 1)
    result = zeros(Float64, n, 3)
    for i in 1:n
        lat, lon, alt = ecef_to_latlon(
            positions[i, 1], positions[i, 2], positions[i, 3])
        result[i, 1] = lat
        result[i, 2] = lon
        result[i, 3] = alt
    end
    return result
end

# ────────────────────────────────────────────────────────────
# GeodeticPosition → 球面 xyz（用于地面站绘制）
# ────────────────────────────────────────────────────────────

"""
    geodetic_to_xyz(position::GeodeticPosition; radius_km)

地理坐标 → 球面 ECEF xyz。默认 alt=0（地面）。
"""
function geodetic_to_xyz(position::GeodeticPosition; radius_km = WGS84_EQUATORIAL_RADIUS_KM)
    return latlon_to_xyz(position.latitude_deg, position.longitude_deg;
        alt_km = position.altitude_km,
        radius_km = radius_km,
    )
end

# ────────────────────────────────────────────────────────────
# ConstellationEphemeris → 裸数组 提取
# ────────────────────────────────────────────────────────────

"""
    ephemeris_to_positions(ephemeris::ConstellationEphemeris) -> Array{Float64,3}

从 ConstellationEphemeris 提取 ECEF 位置矩阵 (N×T×3)。
"""
function ephemeris_to_positions(ephemeris::ConstellationEphemeris)
    n_sat = length(ephemeris.satellites)
    n_time = time_count(ephemeris.time_grid)
    positions = zeros(Float64, n_sat, n_time, 3)

    for (si, sat_eph) in enumerate(ephemeris.satellites)
        for sample in sat_eph.samples
            t = sample.time_index
            t < 1 || t > n_time && continue
            sample.cartesian === nothing && continue
            positions[si, t, 1] = sample.cartesian.position_km[1]
            positions[si, t, 2] = sample.cartesian.position_km[2]
            positions[si, t, 3] = sample.cartesian.position_km[3]
        end
    end

    return positions
end

# ────────────────────────────────────────────────────────────
# 地面站 → 球面 xyz 矩阵
# ────────────────────────────────────────────────────────────

"""
    ground_stations_to_xyz(stations::AbstractVector{GroundStation}) -> Matrix{Float64}

地面站列表 → G×3 ECEF xyz 矩阵（投影到地表）。
"""
function ground_stations_to_xyz(stations::AbstractVector{GroundStation})
    n = length(stations)
    n == 0 && return zeros(Float64, 0, 3)
    xyz = zeros(Float64, n, 3)
    for (i, gs) in enumerate(stations)
        xyz[i, 1], xyz[i, 2], xyz[i, 3] = geodetic_to_xyz(gs.position)
    end
    return xyz
end

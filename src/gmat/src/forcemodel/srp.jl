# ===== 太阳光压力模型（GMAT SolarRadiationPressure）=====
#
# a_srp = -Cr · (A/m) · P_sun · (AU/r_sun)² · r̂_sun
# P_sun = 太阳光压常数 ≈ 4.56e-6 N/m²（1AU 处）
# 阴影（地影）简化为圆锥模型。

using SatelliteSimFoundation: WGS84_EQUATORIAL_RADIUS_KM

export SolarRadiationPressure, SRP

const R_EARTH_M_SRP = WGS84_EQUATORIAL_RADIUS_KM * 1000.0
const SUN_PRESSURE_1AU = 4.56e-6     # N/m²
const AU_M = 1.495978707e11          # 天文单位 (m)

"""
    SolarRadiationPressure

太阳光压力模型。

# 字段
- `area_m2`: 迎光面积（m²）
- `cr`: 光压系数（典型 1.3）
- `shadow_model::Symbol`: 地影模型（:cylinder 圆柱形简化）
"""
struct SolarRadiationPressure <: AbstractForceModel
    area_m2::Float64
    cr::Float64
    shadow_model::Symbol
end

SolarRadiationPressure(; area_m2::Float64=2.0, cr::Float64=1.3, shadow_model::Symbol=:cylinder) =
    SolarRadiationPressure(area_m2, cr, shadow_model)

"""
    acceleration(srp::SolarRadiationPressure, r, v, t, sc) -> SVector{3}

太阳光压加速度。
"""
function acceleration(srp::SolarRadiationPressure, r, v, t, sc)
    # 太阳位置（复用 thirdbody 的简化位置）
    r_sun = GMAT.body_position(:sun, t)
    r_sat_to_sun = r_sun - r
    r_sat_to_sun_mag = norm(r_sat_to_sun)
    r_sat_to_sun_mag == 0.0 && return zero(SVector{3,Float64})

    # 地影因子（圆柱阴影模型简化）
    shadow = _shadow_factor(r, r_sun)

    # 光压（反平方衰减）
    au_ratio = AU_M / r_sat_to_sun_mag
    pressure = SUN_PRESSURE_1AU * au_ratio^2 * shadow

    # 面质比（mass 是 GMAT.mass 函数）
    m = GMAT.mass(sc)
    area_mass = srp.area_m2 / m

    # a = Cr · (A/m) · P · r̂_sat→sun
    accel_mag = srp.cr * area_mass * pressure
    return accel_mag * r_sat_to_sun / r_sat_to_sun_mag
end

"""
    _shadow_factor(r_sat, r_sun) -> Float64

地影因子（0=全影，1=全光照）。圆柱阴影模型简化。
"""
function _shadow_factor(r_sat, r_sun)
    # 卫星在太阳方向的投影距离（垂直于日地连线）
    r_sun_mag = norm(r_sun)
    r_sun_unit = r_sun / r_sun_mag

    # 卫星到地心在垂直日地连线方向的距离
    proj_parallel = dot(r_sat, r_sun_unit)
    r_perp = r_sat - proj_parallel * r_sun_unit
    r_perp_mag = norm(r_perp)

    # 圆柱阴影：若卫星在地球背面（proj_parallel < 0 表示背离太阳）且垂直距离 < 地球半径 → 在影中
    if proj_parallel < 0.0 && r_perp_mag < R_EARTH_M_SRP
        return 0.0  # 全影
    end
    return 1.0      # 全光照
end

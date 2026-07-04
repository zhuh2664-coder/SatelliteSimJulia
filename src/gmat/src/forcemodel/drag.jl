# ===== 大气阻力力模型（GMAT DragForce）=====
#
# a_drag = -0.5 · ρ · (Cd·A/m) · |v_rel| · v_rel
# ρ 用指数大气模型（高度衰减）；v_rel = v - ω_earth × r
#
# 参考：Vallado 式 (8-60)；指数大气：ρ(h) = ρ0·exp(-h/H)

using SatelliteSimFoundation: WGS84_EQUATORIAL_RADIUS_KM, OMEGA_EARTH

export AtmosphericDrag, atmospheric_density, DRAG

const R_EARTH_M_DRAG = WGS84_EQUATORIAL_RADIUS_KM * 1000.0

"""
    AtmosphericDrag

大气阻力力模型。

# 字段
- `area_m2`: 迎风面积（m²）
- `cd`: 阻力系数（典型 2.2）
- `density_model::Symbol`: 大气密度模型（:exponential 简化版）
"""
struct AtmosphericDrag <: AbstractForceModel
    area_m2::Float64
    cd::Float64
    density_model::Symbol
end

AtmosphericDrag(; area_m2::Float64=2.0, cd::Float64=2.2, density_model::Symbol=:exponential) =
    AtmosphericDrag(area_m2, cd, density_model)

"""
    atmospheric_density(altitude_km::Real; model::Symbol=:exponential) -> Float64

大气密度（kg/m³）。指数衰减模型。

简化模型，高度分段拟合：
  - 200km: ~2.5e-10
  - 400km: ~2.8e-12
  - 550km: ~5.5e-13
  - 800km: ~1.0e-14
  - 1000km: ~3.0e-15

参考：US Standard Atmosphere / CIRA 简化。
"""
function atmospheric_density(altitude_km::Real; model::Symbol=:exponential)
    altitude_km < 0 && return 0.0
    altitude_km > 2000 && return 0.0  # 高于 2000km 大气可忽略

    # 分段指数拟合（标高随高度变化）
    # ρ(h) = ρ_ref · exp(-(h - h_ref) / H)
    if altitude_km < 200
        rho0, h0, H = 3.0e-9, 150.0, 30.0
    elseif altitude_km < 400
        rho0, h0, H = 2.5e-10, 200.0, 50.0
    elseif altitude_km < 700
        rho0, h0, H = 2.8e-12, 400.0, 70.0
    elseif altitude_km < 1000
        rho0, h0, H = 1.0e-14, 800.0, 100.0
    else
        rho0, h0, H = 3.0e-15, 1000.0, 150.0
    end
    return rho0 * exp(-(altitude_km - h0) / H)
end

"""
    acceleration(d::AtmosphericDrag, r, v, t, sc) -> SVector{3}

大气阻力加速度。
v_rel = v - ω_earth × r（相对大气速度）
"""
function acceleration(d::AtmosphericDrag, r, v, t, sc)
    r_mag = norm(r)
    altitude_km = (r_mag - R_EARTH_M_DRAG) / 1000.0

    rho = atmospheric_density(altitude_km; model=d.density_model)
    rho == 0.0 && return zero(SVector{3,Float64})

    # 相对大气速度：v - ω × r
    omega_earth = SVector(0.0, 0.0, OMEGA_EARTH)
    v_rel = v - cross(omega_earth, r)
    v_rel_mag = norm(v_rel)

    v_rel_mag == 0.0 && return zero(SVector{3,Float64})

    # 面质比（用航天器总质量；mass 是 GMAT.mass 函数）
    m = GMAT.mass(sc)
    area_mass = d.area_m2 / m

    # a = -0.5 · ρ · (Cd·A/m) · |v_rel| · v_rel
    accel_mag = 0.5 * rho * d.cd * area_mass * v_rel_mag
    return -accel_mag * v_rel / v_rel_mag
end

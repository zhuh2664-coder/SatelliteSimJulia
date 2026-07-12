# ===== 物理约束 =====
# 结构体 + 预设 + 检查函数，全部集中在一个文件。

export PhysicalConstraints, LEO_DEFAULTS

# ── 结构体 ──

"""
    PhysicalConstraints

星座仿真的物理约束参数。
"""
Base.@kwdef struct PhysicalConstraints
    isl_max_range_km::Float64 = 5000.0
    isl_require_los::Bool = true
    isl_max_capacity_mbps::Float64 = 10000.0
    gsl_min_elevation_deg::Float64 = 25.0
    gsl_max_range_km::Float64 = 2000.0
    gsl_base_capacity_mbps::Float64 = 1000.0
    max_isl_per_satellite::Int = 4
    # === ISL 激光终端参数 ===
    isl_max_cone_angle_deg::Float64 = 60.0    # 激光终端半锥角
    isl_min_azimuth_deg::Float64 = 30.0        # 最小方位角
    isl_min_duration_s::Float64 = 10.0         # 最小链路持续时间（秒）
    isl_setup_time_s::Float64 = 2.0            # 链路建立时间（秒）
end

"""LEO (550km) 典型约束值"""
const LEO_DEFAULTS = PhysicalConstraints(
    isl_max_range_km = 5000.0,
    isl_require_los = true,
    isl_max_capacity_mbps = 10000.0,
    gsl_min_elevation_deg = 25.0,
    gsl_max_range_km = 2000.0,
    gsl_base_capacity_mbps = 1000.0,
    max_isl_per_satellite = 4,
    isl_max_cone_angle_deg = 60.0,
    isl_min_azimuth_deg = 30.0,
    isl_min_duration_s = 10.0,
    isl_setup_time_s = 2.0,
)

"""Kuiper (630km, 34×34) 论文约束值"""
const KUIPER_DEFAULTS = PhysicalConstraints(
    isl_max_range_km = 5000.0,
    isl_require_los = true,
    isl_max_capacity_mbps = 10000.0,
    gsl_min_elevation_deg = 25.0,
    gsl_max_range_km = 2000.0,
    gsl_base_capacity_mbps = 1000.0,
    max_isl_per_satellite = 4,
    isl_max_cone_angle_deg = 60.0,
    isl_min_azimuth_deg = 30.0,
    isl_min_duration_s = 291.5,    # T_orbit/P = 5830/20
    isl_setup_time_s = 2.0,
)

"""MEO (~20000km) 典型约束值"""
const MEO_DEFAULTS = PhysicalConstraints(
    isl_max_range_km = 15000.0,
    isl_require_los = true,
    isl_max_capacity_mbps = 5000.0,
    gsl_min_elevation_deg = 10.0,
    gsl_max_range_km = 10000.0,
    gsl_base_capacity_mbps = 500.0,
    max_isl_per_satellite = 6,
    isl_max_cone_angle_deg = 45.0,
    isl_min_azimuth_deg = 20.0,
    isl_min_duration_s = 15.0,
    isl_setup_time_s = 3.0,
)

"""GEO (35786km) 典型约束值"""
const GEO_DEFAULTS = PhysicalConstraints(
    isl_max_range_km = 50000.0,
    isl_require_los = true,
    isl_max_capacity_mbps = 2000.0,
    gsl_min_elevation_deg = 5.0,
    gsl_max_range_km = 40000.0,
    gsl_base_capacity_mbps = 200.0,
    max_isl_per_satellite = 2,
    isl_max_cone_angle_deg = 30.0,
    isl_min_azimuth_deg = 15.0,
    isl_min_duration_s = 20.0,
    isl_setup_time_s = 5.0,
)

# ── 检查函数 ──

"""
    check_isl(distance_km, has_los; constraints=LEO_DEFAULTS) -> Bool

判断 ISL 是否满足物理约束。
"""
function check_isl(distance_km::Real, has_los::Bool; constraints::PhysicalConstraints=LEO_DEFAULTS)
    in_range = distance_km ≤ constraints.isl_max_range_km
    los_ok = !constraints.isl_require_los || has_los
    return in_range && los_ok
end

"""
    check_gsl(distance_km, elevation_deg; constraints=LEO_DEFAULTS) -> Bool

判断 GSL 是否满足物理约束。
"""
function check_gsl(distance_km::Real, elevation_deg::Real; constraints::PhysicalConstraints=LEO_DEFAULTS)
    in_range = distance_km ≤ constraints.gsl_max_range_km
    above_mask = elevation_deg ≥ constraints.gsl_min_elevation_deg
    return in_range && above_mask
end

# ═══════════════════════════════════════════════
# ISL 激光终端检查函数
# ═══════════════════════════════════════════════

"""
    check_isl_elevation(elevation_deg; constraints) -> Bool

判断卫星间相对仰角是否在激光终端半锥角范围内。
"""
function check_isl_elevation(elevation_deg::Real; constraints::PhysicalConstraints=LEO_DEFAULTS)
    return elevation_deg <= constraints.isl_max_cone_angle_deg
end

"""
    check_isl_azimuth(cos_psi, terminal_id; constraints) -> Bool

cos_psi: 方位角cos值（从 compute_azimuth_from_rtn 得到）
terminal_id: 1=前方, 2=后方, 3=左侧, 4=右侧

判断目标卫星是否在指定终端的半锥角 ρ（isl_max_cone_angle_deg）覆盖范围内。
"""
function check_isl_azimuth(cos_psi::Real, terminal_id::Int;
                            constraints::PhysicalConstraints=LEO_DEFAULTS)
    cos_rho = cos(deg2rad(constraints.isl_max_cone_angle_deg))  # 半锥角 ρ

    if terminal_id == 4      # 右侧 (N+)
        return cos_psi >= cos_rho
    elseif terminal_id == 3  # 左侧 (N-)
        return cos_psi <= -cos_rho
    elseif terminal_id == 1  # 前方 (T+)
        return cos_psi > 0   # 简化：前方半平面
    elseif terminal_id == 2  # 后方 (T-)
        return cos_psi < 0   # 简化：后方半平面
    else
        return true
    end
end

"""
    check_isl_duration(duration_s; constraints) -> Bool

判断链路预期持续时间是否满足最小持续时间约束。
"""
function check_isl_duration(duration_s::Real; constraints::PhysicalConstraints=LEO_DEFAULTS)
    return duration_s >= constraints.isl_min_duration_s
end

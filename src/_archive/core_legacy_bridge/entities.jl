module LegacyEntities

# ===== 卫星状态枚举 =====
@enum SatelliteStatus begin
    ACTIVE
    INACTIVE
    FAILED
    DECOMMISSIONED
end

# ===== 卫星静态属性 =====
struct Satellite
    id::String
    norad_id::Union{Int, Nothing}
    isl_antenna_count::Int           # ISL 天线数量
    isl_range_km::Float64            # ISL 最大通信距离 (km)
    laser_cone_angle_deg::Float64    # 激光终端半锥角 (ρ)，典型值 45°-90°
    laser_azimuth_range_deg::Float64 # 激光终端方位角范围 (度)
    laser_setup_time_s::Float64      # 激光链路建立时间 (秒)，典型值 2s
    storage_gb::Float64              # 星载存储 (GB)
    compute_flops::Float64           # 计算能力 (FLOPS)
end

# ===== 卫星动态状态 =====
mutable struct SatelliteState
    satellite_id::String
    x::Float64                       # ECI 位置 X (km)
    y::Float64                       # ECI 位置 Y (km)
    z::Float64                       # ECI 位置 Z (km)
    vx::Float64                      # ECI 速度 X (km/s)
    vy::Float64                      # ECI 速度 Y (km/s)
    vz::Float64                      # ECI 速度 Z (km/s)
    status::SatelliteStatus          # 当前状态
    cached_content::Set{String}      # 缓存内容 ID 列表
end

# ===== 地面站 =====
struct GroundStation
    id::String
    name::String
    lat::Float64                     # 纬度 (度)
    lon::Float64                     # 经度 (度)
    elevation::Float64               # 海拔 (m)
end

# ===== 用户 =====
struct User
    id::String
    lat::Float64                     # 纬度 (度)
    lon::Float64                     # 经度 (度)
    uplink_demand_mbps::Float64      # 上行带宽需求 (Mbps)
    downlink_demand_mbps::Float64    # 下行带宽需求 (Mbps)
    service_type::Union{String, Nothing}  # 业务类型（可选）
end

end # module

# ===== 基础实体 + 接口契约 =====
# Satellite/GroundStation/UserTerminal 是全仓库的基础实体类型。
# AbstractOrbitElementSet 是轨道根数的抽象接口（具体实现由 Orbit 包提供）。
# SatelliteConfig 是卫星硬件配置（实体的组成部分）。

export AbstractOrbitElementSet, SourceMetadata,
       Satellite, GroundStation, UserTerminal,
       SatelliteConfig, DEFAULT_SAT_CONFIG, KUIPER_SAT_CONFIG

using Dates

# ════════════════════════════════════════════════════════════
# 轨道根数抽象接口（具体实现 DesignOrbitElementSet/TLEOrbitElementSet 在 Orbit 包）
# ════════════════════════════════════════════════════════════

abstract type AbstractOrbitElementSet end

struct SourceMetadata
    source::String
    source_url::Union{Nothing,String}
    retrieved_at::Union{Nothing,DateTime}
    raw_payload_hash::Union{Nothing,String}
end
SourceMetadata(source::String) = SourceMetadata(source, nothing, nothing, nothing)

# ════════════════════════════════════════════════════════════
# 卫星硬件配置
# ════════════════════════════════════════════════════════════

Base.@kwdef struct SatelliteConfig
    isl_antenna_count::Int = 4
    isl_range_km::Float64 = 5000.0
    laser_cone_angle_deg::Float64 = 60.0
    laser_azimuth_range_deg::Float64 = 180.0
    laser_setup_time_s::Float64 = 2.0
    storage_gb::Float64 = 100.0
    compute_flops::Float64 = 1e9
end

const DEFAULT_SAT_CONFIG = SatelliteConfig()

const KUIPER_SAT_CONFIG = SatelliteConfig(;
    isl_antenna_count = 4,
    isl_range_km = 5000.0,
    laser_cone_angle_deg = 60.0,
    laser_azimuth_range_deg = 180.0,
    laser_setup_time_s = 2.0,
    storage_gb = 200.0,
    compute_flops = 2e9,
)

# ════════════════════════════════════════════════════════════
# 核心实体（三类）
# ════════════════════════════════════════════════════════════

"""卫星：轨道根数 + 硬件配置"""
Base.@kwdef struct Satellite
    id::Int
    name::Union{Nothing,String} = nothing
    orbit::AbstractOrbitElementSet         # 轨道根数 — 定义了卫星的运动
    config::SatelliteConfig                # 硬件参数 — 定义了卫星的能力
end

"""地面站：固定地面设施"""
Base.@kwdef struct GroundStation
    id::Int
    name::Union{Nothing,String} = nothing
    position::GeodeticPosition             # 经纬高
end

"""用户终端：移动/固定用户设备"""
Base.@kwdef struct UserTerminal
    id::Int
    name::Union{Nothing,String} = nothing
    position::GeodeticPosition             # 用户位置
end

# ===== 基础实体 + 接口契约 =====
# Satellite/GroundStation/UserTerminal 是全仓库的基础实体类型。
# AbstractOrbitElementSet 是轨道根数的抽象接口（具体实现由 Orbit 包提供）。
# SatelliteConfig 是卫星硬件配置（实体的组成部分）。

export AbstractOrbitElementSet, SourceMetadata,
       Satellite, GroundStation, UserTerminal, GroundEndpoint,
       ground_endpoint_tuple,
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

"""地面端点：统一地面站 / 用户终端 / 平台用户

`GroundEndpoint` 是地面侧的唯一事实端点。它把 `GroundStation`、
`UserTerminal` 以及平台 JSON 里的 `users` 统一成同一几何与身份契约，
供 GSL 评估、覆盖率和 Traffic AON 共同消费，避免 GroundUser/GroundStation
/TrafficDemand 之间的歧义转换。
"""
Base.@kwdef struct GroundEndpoint
    id::String
    position::GeodeticPosition
    uplink_demand_mbps::Float64 = 0.0
    downlink_demand_mbps::Float64 = 0.0
    tags::Dict{String,String} = Dict{String,String}()
end

"""从大地坐标构造地面端点（id 为字符串，便于平台/JSON 对齐）。"""
function GroundEndpoint(
    id::AbstractString,
    latitude_deg::Real,
    longitude_deg::Real,
    altitude_km::Real=0.0;
    uplink_demand_mbps::Real=0.0,
    downlink_demand_mbps::Real=0.0,
    tags::Union{AbstractDict{<:AbstractString,<:AbstractString},Nothing}=nothing,
)
    tag_dict = tags === nothing ? Dict{String,String}() :
        Dict{String,String}(String(k) => String(v) for (k, v) in tags)
    # 排序后插入，保证 repr/hash 的确定性。
    sorted_tags = Dict{String,String}()
    for key in sort(collect(keys(tag_dict)))
        sorted_tags[key] = tag_dict[key]
    end
    return GroundEndpoint(
        String(id),
        GeodeticPosition(latitude_deg, longitude_deg, altitude_km),
        Float64(uplink_demand_mbps),
        Float64(downlink_demand_mbps),
        sorted_tags,
    )
end

"""从 GroundStation 构造地面端点（保留原始 int id 为字符串）。"""
GroundEndpoint(station::GroundStation) = GroundEndpoint(
    string(station.id),
    station.position.latitude_deg,
    station.position.longitude_deg,
    station.position.altitude_km;
    tags = station.name === nothing ? Dict{String,String}() :
        Dict{String,String}("name" => String(station.name)),
)

"""从 UserTerminal 构造地面端点（保留原始 int id 为字符串）。"""
GroundEndpoint(terminal::UserTerminal) = GroundEndpoint(
    string(terminal.id),
    terminal.position.latitude_deg,
    terminal.position.longitude_deg,
    terminal.position.altitude_km;
    tags = terminal.name === nothing ? Dict{String,String}() :
        Dict{String,String}("name" => String(terminal.name)),
)

"""提取地面端点的 (lat, lon, alt_km) 元组，供 GSL 评估使用。"""
function ground_endpoint_tuple(endpoint::GroundEndpoint)::NTuple{3,Float64}
    return (
        endpoint.position.latitude_deg,
        endpoint.position.longitude_deg,
        endpoint.position.altitude_km,
    )
end

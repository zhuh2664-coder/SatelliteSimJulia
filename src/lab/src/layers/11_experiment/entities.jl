# ===== Lightweight experiment entities =====

export GroundUser, GroundEndpoint

import SatelliteSimFoundation: GroundEndpoint

struct GroundUser
    id::String
    lat::Float64
    lon::Float64
    uplink_demand_mbps::Float64
    downlink_demand_mbps::Float64
    service_type::Union{String,Nothing}
end

GroundUser(
    id::AbstractString,
    lat::Real,
    lon::Real,
    uplink_demand_mbps::Real=0.0,
    downlink_demand_mbps::Real=0.0,
    service_type::Union{AbstractString,Nothing}=nothing,
) = GroundUser(
    String(id),
    Float64(lat),
    Float64(lon),
    Float64(uplink_demand_mbps),
    Float64(downlink_demand_mbps),
    service_type === nothing ? nothing : String(service_type),
)

"""从 GroundUser 构造统一 GroundEndpoint（保留原始 id 与需求）。"""
function GroundEndpoint(user::GroundUser)::GroundEndpoint
    tags = user.service_type === nothing ? Dict{String,String}() :
        Dict{String,String}("service_type" => user.service_type)
    return GroundEndpoint(
        user.id,
        GeodeticPosition(user.lat, user.lon, 0.0),
        user.uplink_demand_mbps,
        user.downlink_demand_mbps,
        tags,
    )
end

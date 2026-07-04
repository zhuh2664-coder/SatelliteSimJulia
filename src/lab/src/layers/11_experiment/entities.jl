# ===== Lightweight experiment entities =====

export GroundUser

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

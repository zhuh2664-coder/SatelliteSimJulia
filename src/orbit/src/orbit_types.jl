# ===== 轨道根数具体实现 + 组织关系 =====
# 基础实体（Satellite/GroundStation/UserTerminal）、AbstractOrbitElementSet、
# SatelliteConfig 已迁移到 SatelliteSimFoundation（entities.jl）。
# 本文件只保留轨道根数的具体实现和组织关系（属于 Orbit 领域）。

export DesignOrbitElementSet, EarthFixedOrbitElementSet, TLEOrbitElementSet
export Shell, OrbitPlane, EARTH_FIXED_ROTATION_REV_PER_DAY
export group_by_raan, satellites

const EARTH_FIXED_ROTATION_REV_PER_DAY = 7.2921150e-5 * 86_400 / (2 * pi)  # 与 OMEGA_EARTH (Foundation) 同值

_normalize_longitude_deg(lon::Real)::Float64 = mod(Float64(lon) + 180.0, 360.0) - 180.0

"""设计轨道（Walker 星座生成）"""
struct DesignOrbitElementSet <: AbstractOrbitElementSet
    altitude_km::Float64
    inclination_deg::Float64
    raan_deg::Float64
    argument_of_perigee_deg::Float64
    mean_anomaly_deg::Float64
    eccentricity::Float64
    metadata::SourceMetadata
end

function DesignOrbitElementSet(;
    altitude_km::Real,
    inclination_deg::Real,
    raan_deg::Real=0.0,
    argument_of_perigee_deg::Real=0.0,
    mean_anomaly_deg::Real=0.0,
    eccentricity::Real=0.001,
    metadata::SourceMetadata=SourceMetadata("design"),
)
    altitude_km >= 0 || throw(ArgumentError("altitude_km must be non-negative"))
    0 <= inclination_deg <= 180 || throw(ArgumentError("inclination_deg must be in [0, 180]"))
    0 <= eccentricity < 1 || throw(ArgumentError("eccentricity must be in [0, 1)"))
    return DesignOrbitElementSet(
        Float64(altitude_km),
        Float64(inclination_deg),
        Float64(raan_deg),
        Float64(argument_of_perigee_deg),
        Float64(mean_anomaly_deg),
        Float64(eccentricity),
        metadata,
    )
end

Base.propertynames(::DesignOrbitElementSet) = (
    :altitude_km,
    :inclination_deg,
    :raan_deg,
    :argument_of_perigee_deg,
    :mean_anomaly_deg,
    :eccentricity,
    :metadata,
)

"""地固节点轨道根数：用经纬高描述地球固定节点，并保留旧角度字段兼容入口。"""
struct EarthFixedOrbitElementSet <: AbstractOrbitElementSet
    altitude_km::Float64
    latitude_deg::Float64
    longitude_deg::Float64
    inclination_deg::Float64
    raan_deg::Float64
    argument_of_perigee_deg::Float64
    mean_anomaly_deg::Float64
    eccentricity::Float64
    mean_motion_rev_per_day::Float64
    metadata::SourceMetadata
end

function EarthFixedOrbitElementSet(;
    altitude_km::Real=0.0,
    latitude_deg::Union{Nothing,Real}=nothing,
    longitude_deg::Union{Nothing,Real}=nothing,
    inclination_deg::Real=0.0,
    raan_deg::Real=0.0,
    argument_of_perigee_deg::Real=0.0,
    mean_anomaly_deg::Real=0.0,
    eccentricity::Real=0.0,
    mean_motion_rev_per_day::Real=EARTH_FIXED_ROTATION_REV_PER_DAY,
    metadata::SourceMetadata=SourceMetadata("earth-fixed"),
)
    altitude_km >= 0 || throw(ArgumentError("altitude_km must be non-negative"))
    eccentricity == 0 || throw(ArgumentError("earth-fixed nodes must have zero eccentricity"))

    latitude = latitude_deg === nothing ? Float64(inclination_deg) : Float64(latitude_deg)
    -90 <= latitude <= 90 || throw(ArgumentError("latitude_deg must be in [-90, 90]"))

    raw_longitude = longitude_deg === nothing ?
        Float64(raan_deg + argument_of_perigee_deg + mean_anomaly_deg) :
        Float64(longitude_deg)
    longitude = _normalize_longitude_deg(raw_longitude)

    return EarthFixedOrbitElementSet(
        Float64(altitude_km),
        latitude,
        longitude,
        latitude,
        Float64(raan_deg),
        Float64(argument_of_perigee_deg),
        Float64(mean_anomaly_deg),
        0.0,
        Float64(mean_motion_rev_per_day),
        metadata,
    )
end

Base.propertynames(::EarthFixedOrbitElementSet) = (
    :altitude_km,
    :latitude_deg,
    :longitude_deg,
    :inclination_deg,
    :raan_deg,
    :argument_of_perigee_deg,
    :mean_anomaly_deg,
    :eccentricity,
    :mean_motion_rev_per_day,
    :metadata,
)

"""TLE 轨道根数"""
struct TLEOrbitElementSet <: AbstractOrbitElementSet
    name::String
    line1::String
    line2::String
    metadata::SourceMetadata
end

function TLEOrbitElementSet(
    name::AbstractString,
    line1::AbstractString,
    line2::AbstractString;
    metadata::SourceMetadata=SourceMetadata("tle"),
)
    startswith(String(line1), "1 ") || throw(ArgumentError("TLE line1 must start with '1 '"))
    startswith(String(line2), "2 ") || throw(ArgumentError("TLE line2 must start with '2 '"))
    return TLEOrbitElementSet(String(name), String(line1), String(line2), metadata)
end

function Base.getproperty(elements::TLEOrbitElementSet, name::Symbol)
    name === :satellite_name && return getfield(elements, :name)
    return getfield(elements, name)
end

Base.propertynames(::TLEOrbitElementSet) = (:name, :satellite_name, :line1, :line2, :metadata)

"""轨道面：同一 RAAN 下的卫星集合"""
Base.@kwdef struct OrbitPlane
    raan_deg::Float64
    satellites::Vector{Satellite}
end

"""壳层：同一高度和倾角下的轨道面集合"""
Base.@kwdef struct Shell
    altitude_km::Float64
    inclination_deg::Float64
    planes::Vector{OrbitPlane}
end

"""按 RAAN 分组卫星"""
function group_by_raan(satellites::Vector{Satellite})
    groups = Dict{Float64,Vector{Satellite}}()
    for sat in satellites
        raan = sat.orbit isa DesignOrbitElementSet ? sat.orbit.raan_deg : 0.0
        push!(get!(groups, raan, Satellite[]), sat)
    end
    return [OrbitPlane(raan, sats) for (raan, sats) in sort(groups)]
end

satellites(plane::OrbitPlane) = plane.satellites
satellites(shell::Shell) = [sat for p in shell.planes for sat in p.satellites]

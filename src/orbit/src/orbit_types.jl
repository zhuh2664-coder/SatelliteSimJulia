# ===== 轨道根数具体实现 + 组织关系 =====
# 基础实体（Satellite/GroundStation/UserTerminal）、AbstractOrbitElementSet、
# SatelliteConfig 已迁移到 SatelliteSimFoundation（entities.jl）。
# 本文件只保留轨道根数的具体实现和组织关系（属于 Orbit 领域）。

export DesignOrbitElementSet, TLEOrbitElementSet
export Shell, OrbitPlane

const EARTH_FIXED_ROTATION_REV_PER_DAY = 7.2921150e-5 * 86_400 / (2 * pi)  # 与 OMEGA_EARTH (Foundation) 同值

"""设计轨道（Walker 星座生成）"""
struct DesignOrbitElementSet <: AbstractOrbitElementSet
    altitude_km::Float64
    inclination_deg::Float64
    raan_deg::Float64
    eccentricity::Float64
    metadata::SourceMetadata
end

function DesignOrbitElementSet(; altitude_km::Real, inclination_deg::Real,
                                 raan_deg::Real=0.0, eccentricity::Real=0.001,
                                 metadata::SourceMetadata=SourceMetadata("design"))
    return DesignOrbitElementSet(
        Float64(altitude_km), Float64(inclination_deg),
        Float64(raan_deg), Float64(eccentricity), metadata)
end

Base.propertynames(::DesignOrbitElementSet) = (:altitude_km, :inclination_deg, :raan_deg, :eccentricity, :metadata)

"""地固轨道根数"""
struct EarthFixedOrbitElementSet <: AbstractOrbitElementSet
    altitude_km::Float64
    inclination_deg::Float64
    raan_deg::Float64
    eccentricity::Float64
    metadata::SourceMetadata
end

"""TLE 轨道根数"""
struct TLEOrbitElementSet <: AbstractOrbitElementSet
    name::String
    line1::String
    line2::String
end

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

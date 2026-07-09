"""
    OrbitBackend — 轨道后端抽象层

把 SatelliteToolbox.TLE 等外部类型封锁在后端实现文件里。
上层只认本模块定义的内部类型和裸数组 Array{Float64,3}（N×T×3，ECEF km）。

# 现有后端
- JuliaSpaceBackend：生产默认，包装 SatelliteToolbox + SatelliteToolboxSgp4
- StubBackend：CI/离线测试，固定二体传播，零外部依赖
"""
module OrbitBackend

using Dates

export AbstractOrbitBackend
export InternalTLE, InternalKeplerianElements
export propagate_keplerian, propagate_sgp4, teme_to_geodetic, parse_tle_lines

abstract type AbstractOrbitBackend end

struct InternalTLE
    name::String
    line1::String
    line2::String
    mean_motion_rad_s::Float64
    eccentricity::Float64
    inclination_rad::Float64
    raan_rad::Float64
    arg_perigee_rad::Float64
    mean_anomaly_rad::Float64
    bstar::Float64
    epoch::DateTime
end

struct InternalKeplerianElements
    semi_major_axis_m::Float64
    eccentricity::Float64
    inclination_rad::Float64
    raan_rad::Float64
    arg_perigee_rad::Float64
    mean_anomaly_rad::Float64
    epoch::DateTime
end

function propagate_keplerian(
    backend::AbstractOrbitBackend,
    elements::Vector{InternalKeplerianElements},
    time_offsets_s::Vector{<:Integer};
    epoch::DateTime,
)::Array{Float64,3}
    throw(MethodError(propagate_keplerian, (backend, elements, time_offsets_s)))
end

function propagate_sgp4(
    backend::AbstractOrbitBackend,
    tles::Vector{InternalTLE},
    time_offsets_s::Vector{<:Integer};
    epoch::DateTime,
)::Array{Float64,3}
    throw(MethodError(propagate_sgp4, (backend, tles, time_offsets_s)))
end

function teme_to_geodetic(
    backend::AbstractOrbitBackend,
    pos_teme_km::NTuple{3,Float64},
    time::DateTime,
)::NTuple{3,Float64}
    throw(MethodError(teme_to_geodetic, (backend, pos_teme_km, time)))
end

function parse_tle_lines(
    backend::AbstractOrbitBackend,
    lines::Vector{String},
)::Vector{InternalTLE}
    throw(MethodError(parse_tle_lines, (backend, lines)))
end

end # module OrbitBackend

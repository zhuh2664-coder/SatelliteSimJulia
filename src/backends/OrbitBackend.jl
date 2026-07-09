"""
    OrbitBackend — 轨道后端抽象层

把 SatelliteToolbox.TLE、KeplerianElements 等外部类型封锁在后端实现文件里。
上层（foundation / orbit / link / opt）只认本模块定义的内部类型和裸数组。

# 设计原则
- 多重分派：新后端 = 新子类型 + 新方法，不改已有代码
- 输出契约：所有传播接口均输出裸 Array{Float64,3}（N×T×3，ECEF km）
- 旧代码不动：本层与现有 Sgp4PropagatorAdapter 并存，增量迁移

# 现有后端
- JuliaSpaceBackend：生产默认，包装 SatelliteToolbox + SatelliteToolboxSgp4
- StubBackend：CI/离线测试，固定圆轨道，零外部依赖

# 未来后端（远期）
- NativeBackend：纯 Julia 二体/J2，仅标准库
"""
module OrbitBackend

using Dates

export AbstractOrbitBackend
export InternalTLE, InternalKeplerianElements
export propagate_keplerian, propagate_sgp4, teme_to_geodetic, parse_tle_lines

# ── 抽象后端类型 ─────────────────────────────────────────────────────────────

"""
    AbstractOrbitBackend

所有轨道后端的抽象基类型。

后端需实现：
- `propagate_keplerian(backend, elements, time_grid)::Array{Float64,3}`
- `propagate_sgp4(backend, tles, time_grid)::Array{Float64,3}`
- `teme_to_geodetic(backend, pos_teme_km, epoch)::Tuple{Float64,Float64,Float64}`
- `parse_tle_lines(backend, lines)::Vector{InternalTLE}`
"""
abstract type AbstractOrbitBackend end

# ── 内部 TLE 表示 ─────────────────────────────────────────────────────────────

"""
    InternalTLE

项目内部 TLE 表示，不依赖 JuliaSpace 任何外部类型。

所有后端通过 `parse_tle_lines` 返回此类型；上层代码只持有 `InternalTLE`，
后端负责在需要时再转换为各自的外部格式。
"""
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

"""
    InternalKeplerianElements

开普勒轨道根数内部表示，单位 SI（rad, m）。
用于二体/J2 传播器接口；不依赖任何外部库。
"""
struct InternalKeplerianElements
    semi_major_axis_m::Float64
    eccentricity::Float64
    inclination_rad::Float64
    raan_rad::Float64
    arg_perigee_rad::Float64
    mean_anomaly_rad::Float64
    epoch::DateTime
end

# ── 接口定义（默认抛出 MethodError，子类型须实现）────────────────────────────

"""
    propagate_keplerian(backend, elements, time_offsets_s; epoch) -> Array{Float64,3}

开普勒（二体/J2）传播，输出 ECEF 位置裸数组。

# 参数
- `backend::AbstractOrbitBackend`
- `elements::Vector{InternalKeplerianElements}`：N 颗卫星的轨道根数
- `time_offsets_s::Vector{Int}`：相对仿真 epoch 的时间偏移（秒）
- `epoch::DateTime`：仿真 epoch（用于 TEME→ECEF 旋转）

# 返回
`Array{Float64,3}` of shape `(N, T, 3)`，ECEF 坐标，单位 km
"""
function propagate_keplerian(
    backend::AbstractOrbitBackend,
    elements::Vector{InternalKeplerianElements},
    time_offsets_s::Vector{<:Integer};
    epoch::DateTime,
)::Array{Float64,3}
    throw(MethodError(propagate_keplerian, (backend, elements, time_offsets_s)))
end

"""
    propagate_sgp4(backend, tles, time_offsets_s; epoch) -> Array{Float64,3}

SGP4 传播，输出 ECEF 位置裸数组。

# 参数
- `backend::AbstractOrbitBackend`
- `tles::Vector{InternalTLE}`：N 颗卫星的 TLE
- `time_offsets_s::Vector{Int}`：相对仿真 epoch 的时间偏移（秒）
- `epoch::DateTime`：仿真 epoch

# 返回
`Array{Float64,3}` of shape `(N, T, 3)`，ECEF 坐标，单位 km
"""
function propagate_sgp4(
    backend::AbstractOrbitBackend,
    tles::Vector{InternalTLE},
    time_offsets_s::Vector{<:Integer};
    epoch::DateTime,
)::Array{Float64,3}
    throw(MethodError(propagate_sgp4, (backend, tles, time_offsets_s)))
end

"""
    teme_to_geodetic(backend, pos_teme_km, time) -> (lat_deg, lon_deg, alt_km)

将 TEME 坐标转换为 WGS84 经纬高。

# 返回
`(latitude_deg, longitude_deg, altitude_km)` — Float64 三元组
"""
function teme_to_geodetic(
    backend::AbstractOrbitBackend,
    pos_teme_km::NTuple{3,Float64},
    time::DateTime,
)::NTuple{3,Float64}
    throw(MethodError(teme_to_geodetic, (backend, pos_teme_km, time)))
end

"""
    parse_tle_lines(backend, lines) -> Vector{InternalTLE}

解析 TLE 文本行，返回内部 TLE 列表。
每组条目为：可选的名称行 + 第1行 + 第2行（即 2 或 3 行一组）。
"""
function parse_tle_lines(
    backend::AbstractOrbitBackend,
    lines::Vector{String},
)::Vector{InternalTLE}
    throw(MethodError(parse_tle_lines, (backend, lines)))
end

end # module OrbitBackend

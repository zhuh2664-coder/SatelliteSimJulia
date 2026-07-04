module SatelliteSimViz

using CairoMakie
using GeoMakie
using Makie
using SatelliteSimCore

# 重新导出 SatelliteSimCore 中 viz 需要的类型（方便用户只用 using SatelliteSimViz）
import SatelliteSimCore: GeodeticPosition, GroundStation,
    WGS84_EQUATORIAL_RADIUS_KM, OMEGA_EARTH,
    time_count

# ── 子文件 include（按依赖顺序）──
include("config.jl")
include("coastline_data.jl")
include("earth.jl")
include("bridge.jl")
include("satellite.jl")
include("links.jl")
include("beam_footprints.jl")
include("ground_track.jl")
include("coverage_heatmap.jl")
include("animation.jl")
include("dashboard.jl")
include("api.jl")

end # module

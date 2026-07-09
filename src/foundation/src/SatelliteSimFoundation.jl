module SatelliteSimFoundation

# SatelliteSimFoundation — 物理基础层（最底层包）
#
# 包含：时间系统、坐标系、几何常量、基础类型契约
# 不包含：任何领域逻辑（轨道/链路/拓扑/路由/指标）
# 所有人依赖此包，此包不依赖任何 SatelliteSim 包。

include("time.jl")
include("frames.jl")
include("geometry_constants.jl")
include("entities.jl")
include("experiment_variables.jl")
include("link_types.jl")
include("exports.jl")

end # module

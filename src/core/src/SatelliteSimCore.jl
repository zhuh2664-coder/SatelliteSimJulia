module SatelliteSimCore

# ============================================================
# SatelliteSimCore — 仿真内核（聚合包）
#
# 物理基础 → SatelliteSimFoundation（时间/坐标/常量/实体）
# 轨道     → SatelliteSimOrbit（walker/propagator/ephemeris）
# 链路     → SatelliteSimLink（evaluator/constraints/geometry）
# 指标     → SatelliteSimMetrics（coverage/latency/capacity）
#
# Core 通过 @reexport 透传所有子包符号，下游 using SatelliteSimCore 无感知。
# Core 自身只保留 catalog（星座/路由/流量/约束/地面站目录元数据）。
# ============================================================

using Reexport
using Dates
@reexport using SatelliteSimFoundation
@reexport using SatelliteSimOrbit
@reexport using SatelliteSimLink
@reexport using SatelliteSimMetrics

# ── Core 自有：目录元数据 ────────────────────────────────────
include("shared/catalog/constellations.jl")
include("shared/catalog/routing.jl")
include("shared/catalog/traffic.jl")
include("shared/catalog/constraint.jl")
include("shared/catalog/groundstation.jl")

end # module

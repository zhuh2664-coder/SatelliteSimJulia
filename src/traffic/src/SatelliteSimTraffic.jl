module SatelliteSimTraffic

# SatelliteSimTraffic — 流量分配层
# 消费 Net 的路由结果 + Link 的物理链路序列，产出链路负载样本
# 依赖方向：Foundation ← Link ← Net ← Traffic

using SatelliteSimFoundation
using SatelliteSimLink
using SatelliteSimCore
using SatelliteSimNet

include("aon.jl")
include("demand_patterns.jl")
include("time_varying.jl")
include("traffic_bridge.jl")
include("energy.jl")
include("power_state.jl")

end # module

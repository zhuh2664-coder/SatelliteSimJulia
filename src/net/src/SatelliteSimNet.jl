module SatelliteSimNet

using Graphs
using SatelliteSimCore

# 信任 Core 的 export 列表，不逐符号 import（Julia 规范）。
# 个别不在 export 中的符号在调用处按需用 SatelliteSimCore.<name> 限定访问。

include("layers/03_topology/abstract.jl")
include("layers/03_topology/grid_plus.jl")
include("layers/03_topology/tshape.jl")
include("layers/03_topology/spiral.jl")
include("layers/03_topology/honeycomb.jl")
include("layers/03_topology/ring.jl")
include("layers/03_topology/mesh.jl")
include("layers/03_topology/nearest_neighbor.jl")

include("layers/04_routing/abstract.jl")
include("layers/04_routing/access.jl")
include("layers/04_routing/handover_policy.jl")
include("layers/04_routing/core_routing.jl")
include("layers/04_routing/dijkstra.jl")
include("layers/04_routing/advanced_routing.jl")
include("layers/04_routing/pinn_routing.jl")

end # module

module SatelliteSimNet

using Graphs
# Net 直接依赖所需的底层领域包，避免通过 Core 的聚合 re-export 形成隐式边界。
using SatelliteSimFoundation
using SatelliteSimLink

include("layers/03_topology/abstract.jl")
include("layers/03_topology/grid_plus.jl")
include("layers/03_topology/tshape.jl")
include("layers/03_topology/spiral.jl")
include("layers/03_topology/honeycomb.jl")
include("layers/03_topology/ring.jl")
include("layers/03_topology/mesh.jl")
include("layers/03_topology/nearest_neighbor.jl")

include("layers/04_routing/abstract.jl")
include("layers/04_routing/handover_policy.jl")
include("layers/04_routing/access.jl")
include("layers/04_routing/core_routing.jl")
include("layers/04_routing/dijkstra.jl")
include("layers/04_routing/advanced_routing.jl")
include("layers/04_routing/pinn_routing.jl")
include("layers/04_routing/cgr.jl")

end # module

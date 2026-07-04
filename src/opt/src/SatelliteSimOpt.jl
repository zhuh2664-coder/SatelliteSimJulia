module SatelliteSimOpt

using SatelliteSimCore
using Random
using Statistics
using Enzyme
using Lux
using Optimisers
using Zygote

# Differentiable orbit and routing utilities.
include("layers/01_orbit/propagator_keplerian.jl")
include("layers/01_orbit/propagator_j2_differentiable.jl")
include("layers/01_orbit/propagator_differentiable.jl")
include("layers/03_topology/soft_isl.jl")
include("layers/04_routing/differentiable_routing.jl")
include("layers/04_routing/pinn_model.jl")
include("layers/04_routing/pinn_routing.jl")

# Optimization primitives.
include("layers/06_optimization/coverage.jl")
include("layers/06_optimization/loss.jl")
include("layers/06_optimization/differentiable_metrics.jl")
include("layers/06_optimization/soft_selection.jl")
include("layers/06_optimization/adam.jl")
include("layers/06_optimization/coverage_optimizer.jl")
include("layers/06_optimization/end_to_end_gradient.jl")

# Capacity optimization helpers.
include("layers/06_optimization/capacity/models.jl")
include("layers/06_optimization/capacity/differentiable.jl")
include("layers/06_optimization/capacity/bottleneck.jl")
include("layers/06_optimization/capacity/losses.jl")
include("layers/06_optimization/capacity/metrics.jl")
include("layers/06_optimization/capacity/optimizer.jl")

end # module

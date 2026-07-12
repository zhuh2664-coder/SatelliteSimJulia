module SatelliteSimOpt

# Opt 直接依赖其使用的领域包，不通过 Core 的聚合 re-export 获取类型或常量。
using SatelliteSimFoundation
using SatelliteSimOrbit
using SatelliteSimLink
using SatelliteSimNet
using Random
using Statistics
using Enzyme
using Lux
using Optimisers
using Zygote

# Public differentiable-simulation API.  Opt remains an explicit optional
# package (it is intentionally not re-exported by the root umbrella package),
# but scripts that activate the Opt environment should not depend on internal
# module qualification.
export MU_KM3_S2, R_EARTH_KM, OMEGA_EARTH,
       satellite_ecef, teme_to_ecef_simple, constellation_positions,
       walker_raans, walker_mas,
       satellite_ecef_j2, constellation_positions_j2, j2_mean_elements,
       isl_adjacency, cross_plane_isl_count, soft_cross_plane_isl,
       NoisyORCoverage, LeakyRevisit, relax, soft_coverage,
       noisy_or_coverage, leaky_revisit, logsumexp_max, ground_grid,
       coverage_loss, coverage_depth_loss, end_to_end_loss, deadzone_scan_loss,
       sgp4_constellation_series, sgp4_series_ecef,
       coverage_loss_vjp, sgp4_e2e_gradient,
       AdamState, adam_step!, adam_optimize, evaluate_constellation,
       build_visibility, soft_select_capacity, hard_eval_topM, hard_eval_diversity,
       CapacityOptimizationSnapshot, CapacityLossWeights, bottleneck_snapshots,
       smooth_sigmoid, softmax_weights, soft_congestion, congestion_loss,
       defense_cost, congested_ratio, average_utilization,
       finite_difference_gradient, projected_gradient_descent

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
include("layers/06_optimization/sgp4_e2e.jl")
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

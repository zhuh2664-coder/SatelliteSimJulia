#!/usr/bin/env julia

using Printf
using SatelliteSimLab
using SatelliteSimNet

config = SatelliteSimLab.ExperimentConfig(
    name = "core-net-lab-smoke",
    constellation_params = Dict(
        :T => 6.0,
        :P => 3.0,
        :F => 1.0,
        :alt_km => 550.0,
        :inc_deg => 53.0,
    ),
    tspan = [0.0, 60.0],
    topology_strategy = SatelliteSimNet.GridPlusStrategy(),
    routing_algorithm = SatelliteSimNet.DijkstraRouting(),
    users = [
        SatelliteSimLab.GroundUser("beijing", 39.9042, 116.4074, 20.0, 100.0, "smoke"),
        SatelliteSimLab.GroundUser("singapore", 1.3521, 103.8198, 20.0, 100.0, "smoke"),
    ],
    ground_pairs = [(1, 4), (2, 5), (3, 6)],
)

result = SatelliteSimLab.run_experiment(config)

println("SMOKE SUCCESS")
println("experiment=$(result.config.name)")
@printf("duration_s=%.3f\n", result.duration_s)
@printf("coverage_ratio=%.3f covered=%d/%d\n",
    result.coverage.coverage_ratio,
    length(result.coverage.covered_users),
    result.coverage.total_users,
)
@printf("avg_latency_ms=%.3f path_count=%d\n",
    result.latency.avg_latency_ms,
    result.latency.path_count,
)
@printf("connectivity_ratio=%.3f connected=%s\n",
    result.network.connectivity_ratio,
    string(result.network.is_connected),
)
@printf("avg_utilization=%.3f bottlenecks=%d\n",
    result.utilization.avg_utilization,
    length(result.utilization.bottleneck_links),
)
@printf("avg_hop_count=%.3f route_success_ratio=%.3f fitness=%.3f\n",
    result.routing_metrics.avg_hop_count,
    result.routing_metrics.success_rate,
    result.fitness,
)

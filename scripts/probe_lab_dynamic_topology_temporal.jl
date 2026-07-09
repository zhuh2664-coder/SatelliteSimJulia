#!/usr/bin/env julia

using Test
using SatelliteSimCore
using SatelliteSimLab
using SatelliteSimNet

@testset "Lab dynamic topology temporal boundary" begin
    positions = zeros(Float64, 4, 2, 3)

    # t=1 nearest-neighbor pairs are (1,2) and (3,4).
    positions[1, 1, :] .= (0.0, 0.0, 0.0)
    positions[2, 1, :] .= (1.0, 0.0, 0.0)
    positions[3, 1, :] .= (10.0, 0.0, 0.0)
    positions[4, 1, :] .= (11.0, 0.0, 0.0)

    # t=2 nearest-neighbor pairs churn to (1,3) and (2,4).
    positions[1, 2, :] .= (0.0, 0.0, 0.0)
    positions[3, 2, :] .= (1.0, 0.0, 0.0)
    positions[2, 2, :] .= (10.0, 0.0, 0.0)
    positions[4, 2, :] .= (11.0, 0.0, 0.0)

    constraints = PhysicalConstraints(
        isl_max_range_km=1000.0,
        isl_require_los=false,
    )

    fixed_strategy = NearestNeighborStrategy(positions=positions, k=1, time_step=1)
    fixed_D = assess_routing_temporal(positions, 4, 2, fixed_strategy, constraints)
    dynamic_D = assess_routing_temporal_dynamic(
        positions,
        4,
        2,
        t -> NearestNeighborStrategy(positions=positions, k=1, time_step=t),
        constraints,
    )

    @test isfinite(fixed_D[1][1, 2])
    @test isinf(fixed_D[1][1, 3])
    @test isfinite(fixed_D[2][1, 2])
    @test isinf(fixed_D[2][1, 3])

    @test isfinite(dynamic_D[1][1, 2])
    @test isinf(dynamic_D[1][1, 3])
    @test isinf(dynamic_D[2][1, 2])
    @test isfinite(dynamic_D[2][1, 3])
end

println("LAB DYNAMIC TOPOLOGY TEMPORAL: ALL PASS")

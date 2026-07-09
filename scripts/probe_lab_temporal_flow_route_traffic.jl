#!/usr/bin/env julia

using Test
using SatelliteSimCore
using SatelliteSimNet
using SatelliteSimTraffic
using SatelliteSimLab

@testset "Lab temporal topology drives per-flow route over traffic demands" begin
    n_sat = 4
    n_planes = 1
    positions = zeros(Float64, n_sat, 2, 3)

    # t=1 nearest-neighbor graph gives demand 1 -> 4 the path 1-2-4.
    positions[1, 1, :] .= (0.0, 0.0, 0.0)
    positions[2, 1, :] .= (1.0, 0.0, 0.0)
    positions[4, 1, :] .= (2.0, 0.0, 0.0)
    positions[3, 1, :] .= (100.0, 0.0, 0.0)

    # t=2 nearest-neighbor graph churns, so the same demand routes as 1-3-4.
    positions[1, 2, :] .= (0.0, 0.0, 0.0)
    positions[3, 2, :] .= (1.0, 0.0, 0.0)
    positions[4, 2, :] .= (2.0, 0.0, 0.0)
    positions[2, 2, :] .= (100.0, 0.0, 0.0)

    constraints = PhysicalConstraints(
        isl_max_range_km=1_000.0,
        isl_require_los=false,
    )
    demand = TrafficDemand(
        id=1,
        source_ground_id=1,
        destination_ground_id=4,
        start_elapsed_s=0,
        end_elapsed_s=120,
        rate_mbps=50.0,
    )
    frames = assess_temporal_flow_routes(
        positions,
        n_sat,
        n_planes,
        t -> NearestNeighborStrategy(positions=positions, k=1, time_step=t),
        constraints,
        [demand],
        DijkstraRouting();
        elapsed_by_time = [0, 60],
    )

    @test length(frames) == 2
    @test [length(frame.active_demands) for frame in frames] == [1, 1]
    @test [frame.routes[1].algorithm for frame in frames] == ["Dijkstra", "Dijkstra"]
    @test frames[1].routes[1].path == [1, 2, 4]
    @test frames[2].routes[1].path == [1, 3, 4]
    @test all(frame -> isfinite(frame.routes[1].total_weight), frames)
    @test all(frame -> length(frame.link_loads) == 2, frames)
    @test sort([(load.endpoint_a_id, load.endpoint_b_id) for load in frames[1].link_loads]) == [(1, 2), (2, 4)]
    @test sort([(load.endpoint_a_id, load.endpoint_b_id) for load in frames[2].link_loads]) == [(1, 3), (3, 4)]
    @test all(frame -> all(load -> load.load_mbps == 50.0, frame.link_loads), frames)
end

println("LAB TEMPORAL FLOW ROUTE TRAFFIC: ALL PASS")

#!/usr/bin/env julia

using Test
using SatelliteSimCore
using SatelliteSimLink
using SatelliteSimNet
using SatelliteSimTraffic

function make_isl_sample(link_id, time_index, elapsed_s, src, dst)
    return ISLPhysicalLinkSample(
        link_id=link_id,
        time_index=time_index,
        elapsed_s=elapsed_s,
        endpoint_a_id=src,
        endpoint_b_id=dst,
        distance_km=1000.0,
        propagation_delay_s=1.0,
        capacity_mbps=100.0,
        state=LinkAvailable(),
        line_of_sight=true,
    )
end

function make_access_decisions(ground_id, selected_satellite_id, grid)
    return [
        AccessDecision(
            ground_id=ground_id,
            time_index=t,
            selected_satellite_id=selected_satellite_id,
            selected_sample=nothing,
        )
        for t in 1:time_count(grid)
    ]
end

@testset "TrafficEvaluation MinLoad bridge" begin
    grid = SimulationTimeGrid(default_starlink_simulation_epoch(), 60, 60)
    edges = [(1, 2), (2, 4), (1, 3), (3, 4)]
    links = [
        SatelliteSimLink.SatelliteLink(
            id=i,
            endpoint_a=SatelliteSimLink.LinkEndpoint(src),
            endpoint_b=SatelliteSimLink.LinkEndpoint(dst),
            state=LinkAvailable(),
            delay_s=1.0,
            capacity_mbps=100.0,
        )
        for (i, (src, dst)) in enumerate(edges)
    ]
    topology = SatelliteSimLink.ConstellationTopology("diamond", links)
    samples_by_time = [
        [make_isl_sample(i, t, (t - 1) * 60, src, dst) for (i, (src, dst)) in enumerate(edges)]
        for t in 1:time_count(grid)
    ]
    isl_series = ISLPhysicalLinkSeries(topology, grid, samples_by_time)
    access_table = AccessDecisionTable(
        grid,
        Dict(
            1 => make_access_decisions(1, 1, grid),
            4 => make_access_decisions(4, 4, grid),
        ),
    )
    demands = [
        TrafficDemand(
            id=1,
            source_ground_id=1,
            destination_ground_id=4,
            start_elapsed_s=0,
            end_elapsed_s=60,
            rate_mbps=100.0,
        ),
        TrafficDemand(
            id=2,
            source_ground_id=1,
            destination_ground_id=4,
            start_elapsed_s=0,
            end_elapsed_s=60,
            rate_mbps=100.0,
        ),
    ]

    ev = evaluate_traffic(demands, isl_series, access_table, MinLoadRouting())

    @test ev isa TrafficEvaluation
    @test ev.time_grid === grid
    @test length(ev.assignments_by_time[1]) == 2
    @test isempty(ev.assignments_by_time[2])

    paths = [assignment.route.satellite_path for assignment in ev.assignments_by_time[1]]
    @test sort(paths) == sort([[1, 2, 4], [1, 3, 4]])
    @test ev.assignments_by_time[1][1].route.reason == :min_load
    @test ev.assignments_by_time[1][2].route.reason == :min_load

    isl_loads = [
        load for load in ev.link_loads_by_time[1]
        if load.link_type == :isl
    ]
    @test length(isl_loads) == 4
    @test all(load -> load.load_mbps == 100.0, isl_loads)
    @test all(load -> load.capacity_mbps == 100.0, isl_loads)
    @test all(load -> load.utilization == 1.0, isl_loads)
end

println("TRAFFIC EVALUATION MINLOAD BRIDGE: ALL PASS")

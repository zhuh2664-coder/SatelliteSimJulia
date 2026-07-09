#!/usr/bin/env julia

using Test
using SatelliteSimFoundation
using SatelliteSimTraffic

@testset "Traffic AON and power probe" begin
    grid = SimulationTimeGrid(default_starlink_simulation_epoch(), 60, 60)
    positions = zeros(Float64, 2, 2, 3)
    isl_pairs = [(1, 2)]

    isl_results_by_time = [
        [(distance_km=1000.0, available=true, line_of_sight=true)]
        for _ in 1:time_count(grid)
    ]
    gsl_avail_by_time = [Bool[1 1; 1 1] for _ in 1:time_count(grid)]
    gsl_dist_by_time = [fill(500.0, 2, 2) for _ in 1:time_count(grid)]
    gsl_elev_by_time = [Float64[80 10; 10 80] for _ in 1:time_count(grid)]

    demands = [
        TrafficDemand(
            id=1,
            source_ground_id=1,
            destination_ground_id=2,
            start_elapsed_s=0,
            end_elapsed_s=60,
            rate_mbps=100.0,
        ),
    ]

    ev = evaluate_traffic_from_bare_arrays(
        positions,
        isl_pairs,
        isl_results_by_time,
        gsl_avail_by_time,
        gsl_dist_by_time,
        gsl_elev_by_time,
        [1, 2],
        grid,
        demands;
        isl_capacity_mbps=1000.0,
        gsl_capacity_mbps=500.0,
    )

    @test ev isa TrafficEvaluation
    @test ev.time_grid === grid
    @test ev.demands == demands
    @test length(ev.assignments_by_time) == 2
    @test length(ev.assignments_by_time[1]) == 1
    @test isempty(ev.assignments_by_time[2])

    assignment = ev.assignments_by_time[1][1]
    @test assignment.demand_id == 1
    @test assignment.time_index == 1
    @test assignment.elapsed_s == 0
    @test assignment.offered_mbps == 100.0
    @test assignment.carried_mbps == 100.0
    @test assignment.dropped_mbps == 0.0
    @test assignment.route.reachable
    @test assignment.route.satellite_path == [1, 2]
    @test assignment.route.isl_link_ids == [1]

    @test length(ev.link_loads_by_time[1]) == 3
    @test any(
        load -> load.link_type == :isl && load.link_id == 1 && load.load_mbps == 100.0,
        ev.link_loads_by_time[1],
    )
    @test count(load -> load.link_type == :gsl && load.load_mbps == 100.0, ev.link_loads_by_time[1]) == 2

    loads = evaluate_satellite_communication_loads(ev, 2)

    @test loads.time_grid === grid
    @test loads.satellite_count == 2
    @test length(loads.loads_by_time) == 2

    sat1 = loads.loads_by_time[1][1]
    sat2 = loads.loads_by_time[1][2]

    @test sat1.gsl_load_mbps == 100.0
    @test sat1.isl_tx_load_mbps == 100.0
    @test sat1.isl_rx_load_mbps == 0.0
    @test sat1.communication_load_w == 3.0

    @test sat2.gsl_load_mbps == 100.0
    @test sat2.isl_tx_load_mbps == 0.0
    @test sat2.isl_rx_load_mbps == 100.0
    @test sat2.communication_load_w == 3.0

    power = evolve_power_states(loads, 100.0, UniformSolar(0.0); initial_soc=1.0)

    @test power.time_grid === grid
    @test power.satellite_count == 2
    @test length(power.states_by_time) == 2
    @test power.states_by_time[1][1].soc == 1.0
    @test power.states_by_time[1][1].time_index == 0
    @test power.states_by_time[2][1].comm_load_w == 3.0
    @test power.states_by_time[2][1].solar_input_w == 0.0
    @test power.states_by_time[2][1].in_eclipse == false
    @test power.states_by_time[2][1].soc ≈ 0.9994736842105263
end

println("TRAFFIC AON POWER: ALL PASS")

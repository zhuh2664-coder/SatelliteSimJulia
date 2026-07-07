# test/traffic/test_traffic_bridge.jl — 裸数组流量桥接回归测试

using SatelliteSimJulia
using Test

const TRAFFIC_BRIDGE_ATOL = 1e-9
const TRAFFIC_BRIDGE_LIGHT_SPEED_KM_S = 299792.458

traffic_bridge_grid() = SimulationTimeGrid(default_starlink_simulation_epoch(), 60, 60)

function traffic_bridge_inputs(;
    isl_available::Bool = true,
    destination_visible::Bool = true,
)
    grid = traffic_bridge_grid()
    positions = zeros(Float64, 2, time_count(grid), 3)
    isl_pairs = Tuple{Int,Int}[(1, 2)]
    isl_results_by_time = [
        [(distance_km = 1000.0, available = isl_available, line_of_sight = isl_available)]
        for _ in 1:time_count(grid)
    ]

    gsl_availability = destination_visible ? Bool[true true; true true] : Bool[true false; true false]
    gsl_distance = fill(500.0, 2, 2)
    gsl_elevation = Float64[80.0 10.0; 10.0 80.0]

    gsl_avail_by_time = [copy(gsl_availability) for _ in 1:time_count(grid)]
    gsl_dist_by_time = [copy(gsl_distance) for _ in 1:time_count(grid)]
    gsl_elev_by_time = [copy(gsl_elevation) for _ in 1:time_count(grid)]
    ground_ids = [1, 2]
    demands = TrafficDemand[
        TrafficDemand(
            id = 1,
            source_ground_id = 1,
            destination_ground_id = 2,
            start_elapsed_s = 0,
            end_elapsed_s = 60,
            rate_mbps = 100.0,
        ),
    ]

    return (
        grid = grid,
        positions = positions,
        isl_pairs = isl_pairs,
        isl_results_by_time = isl_results_by_time,
        gsl_avail_by_time = gsl_avail_by_time,
        gsl_dist_by_time = gsl_dist_by_time,
        gsl_elev_by_time = gsl_elev_by_time,
        ground_ids = ground_ids,
        demands = demands,
    )
end

function traffic_bridge_evaluate(; isl_available::Bool = true, destination_visible::Bool = true)
    fixture = traffic_bridge_inputs(
        isl_available = isl_available,
        destination_visible = destination_visible,
    )
    evaluation = evaluate_traffic_from_bare_arrays(
        fixture.positions,
        fixture.isl_pairs,
        fixture.isl_results_by_time,
        fixture.gsl_avail_by_time,
        fixture.gsl_dist_by_time,
        fixture.gsl_elev_by_time,
        fixture.ground_ids,
        fixture.grid,
        fixture.demands;
        isl_capacity_mbps = 1000.0,
        gsl_capacity_mbps = 500.0,
        constellation_name = "traffic-bridge-test",
    )
    return fixture, evaluation
end

@testset "bare-array traffic bridge carries reachable demand" begin
    fixture, evaluation = traffic_bridge_evaluate()

    @test evaluation isa TrafficEvaluation
    @test evaluation.time_grid === fixture.grid
    @test evaluation.demands == fixture.demands
    @test length(evaluation.assignments_by_time) == 2
    @test length(evaluation.assignments_by_time[1]) == 1
    @test isempty(evaluation.assignments_by_time[2])
    @test isempty(evaluation.link_loads_by_time[2])

    assignment = only(evaluation.assignments_by_time[1])
    route = assignment.route
    @test assignment.demand_id == 1
    @test assignment.time_index == 1
    @test assignment.elapsed_s == 0
    @test isapprox(assignment.offered_mbps, 100.0; atol = TRAFFIC_BRIDGE_ATOL)
    @test isapprox(assignment.carried_mbps, 100.0; atol = TRAFFIC_BRIDGE_ATOL)
    @test isapprox(assignment.dropped_mbps, 0.0; atol = TRAFFIC_BRIDGE_ATOL)
    @test route.reachable
    @test route.reason == :shortest_delay
    @test route.source_access_satellite_id == 1
    @test route.destination_access_satellite_id == 2
    @test route.satellite_path == [1, 2]
    @test route.isl_link_ids == [1]

    expected_isl_delay = 1000.0 / TRAFFIC_BRIDGE_LIGHT_SPEED_KM_S
    expected_gsl_delay = 500.0 / TRAFFIC_BRIDGE_LIGHT_SPEED_KM_S
    @test isapprox(route.isl_delay_s, expected_isl_delay; atol = TRAFFIC_BRIDGE_ATOL)
    @test isapprox(route.source_gsl_delay_s, expected_gsl_delay; atol = TRAFFIC_BRIDGE_ATOL)
    @test isapprox(route.destination_gsl_delay_s, expected_gsl_delay; atol = TRAFFIC_BRIDGE_ATOL)
    @test isapprox(route.total_delay_s, expected_isl_delay + 2 * expected_gsl_delay; atol = TRAFFIC_BRIDGE_ATOL)

    loads = evaluation.link_loads_by_time[1]
    isl_loads = filter(load -> load.link_type == :isl, loads)
    gsl_loads = filter(load -> load.link_type == :gsl, loads)
    @test length(loads) == 3
    @test length(isl_loads) == 1
    @test length(gsl_loads) == 2

    isl_load = only(isl_loads)
    @test isl_load.link_id == 1
    @test isl_load.endpoint_a_id == 1
    @test isl_load.endpoint_b_id == 2
    @test isapprox(isl_load.load_mbps, 100.0; atol = TRAFFIC_BRIDGE_ATOL)
    @test isapprox(isl_load.capacity_mbps, 1000.0; atol = TRAFFIC_BRIDGE_ATOL)
    @test isapprox(isl_load.utilization, 0.1; atol = TRAFFIC_BRIDGE_ATOL)
    @test !isl_load.congested

    @test all(load -> isapprox(load.load_mbps, 100.0; atol = TRAFFIC_BRIDGE_ATOL), gsl_loads)
    @test all(load -> isapprox(load.capacity_mbps, 500.0; atol = TRAFFIC_BRIDGE_ATOL), gsl_loads)
    @test all(load -> isapprox(load.utilization, 0.2; atol = TRAFFIC_BRIDGE_ATOL), gsl_loads)
    @test all(load -> !load.congested, gsl_loads)
end

@testset "bare-array traffic bridge drops demand without destination access" begin
    _, evaluation = traffic_bridge_evaluate(destination_visible = false)

    @test length(evaluation.assignments_by_time[1]) == 1
    assignment = only(evaluation.assignments_by_time[1])
    route = assignment.route
    @test !route.reachable
    @test route.reason == :destination_no_access
    @test route.source_access_satellite_id == 1
    @test route.destination_access_satellite_id === nothing
    @test isapprox(assignment.offered_mbps, 100.0; atol = TRAFFIC_BRIDGE_ATOL)
    @test isapprox(assignment.carried_mbps, 0.0; atol = TRAFFIC_BRIDGE_ATOL)
    @test isapprox(assignment.dropped_mbps, 100.0; atol = TRAFFIC_BRIDGE_ATOL)
    @test isempty(evaluation.link_loads_by_time[1])
end

@testset "bare-array traffic bridge drops demand when unique ISL is unavailable" begin
    _, evaluation = traffic_bridge_evaluate(isl_available = false)

    @test length(evaluation.assignments_by_time[1]) == 1
    assignment = only(evaluation.assignments_by_time[1])
    route = assignment.route
    @test !route.reachable
    @test route.reason == :isl_unreachable
    @test route.source_access_satellite_id == 1
    @test route.destination_access_satellite_id == 2
    @test isapprox(assignment.offered_mbps, 100.0; atol = TRAFFIC_BRIDGE_ATOL)
    @test isapprox(assignment.carried_mbps, 0.0; atol = TRAFFIC_BRIDGE_ATOL)
    @test isapprox(assignment.dropped_mbps, 100.0; atol = TRAFFIC_BRIDGE_ATOL)
    @test isempty(evaluation.link_loads_by_time[1])
end

@testset "bare-array traffic bridge preserves link delay outputs" begin
    fixture = traffic_bridge_inputs()
    isl_results_by_time = [
        [(distance_km = 1000.0, available = true, line_of_sight = true, latency_ms = 42.0)]
        for _ in 1:time_count(fixture.grid)
    ]
    gsl_delay_ms_by_time = [
        Float64[7.0 13.0; 17.0 11.0]
        for _ in 1:time_count(fixture.grid)
    ]

    evaluation = evaluate_traffic_from_bare_arrays(
        fixture.positions,
        fixture.isl_pairs,
        isl_results_by_time,
        fixture.gsl_avail_by_time,
        fixture.gsl_dist_by_time,
        fixture.gsl_elev_by_time,
        fixture.ground_ids,
        fixture.grid,
        fixture.demands;
        isl_capacity_mbps = 1000.0,
        gsl_capacity_mbps = 500.0,
        gsl_delay_ms_by_time = gsl_delay_ms_by_time,
    )

    route = only(evaluation.assignments_by_time[1]).route
    @test route.reachable
    @test isapprox(route.isl_delay_s, 0.042; atol = TRAFFIC_BRIDGE_ATOL)
    @test isapprox(route.source_gsl_delay_s, 0.007; atol = TRAFFIC_BRIDGE_ATOL)
    @test isapprox(route.destination_gsl_delay_s, 0.011; atol = TRAFFIC_BRIDGE_ATOL)
    @test isapprox(route.total_delay_s, 0.060; atol = TRAFFIC_BRIDGE_ATOL)
end

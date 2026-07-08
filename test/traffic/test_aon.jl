# test/traffic/test_aon.jl — AON 流量分配回归测试

using SatelliteSimJulia
using Test

const TRAFFIC_AON_LINK = SatelliteSimJulia.SatelliteSimCore.SatelliteSimLink

const TRAFFIC_AON_ATOL = 1e-9

traffic_aon_grid() = SimulationTimeGrid(default_starlink_simulation_epoch(), 60, 60)

function traffic_aon_isl_series(
    grid::SimulationTimeGrid,
    edges::Vector{Tuple{Int,Int}};
    capacity_mbps::Float64 = 100.0,
    propagation_delay_s::Float64 = 1.0,
    available::Bool = true,
)::ISLPhysicalLinkSeries
    links = [
        TRAFFIC_AON_LINK.SatelliteLink(
            id = link_id,
            endpoint_a = TRAFFIC_AON_LINK.LinkEndpoint(src),
            endpoint_b = TRAFFIC_AON_LINK.LinkEndpoint(dst),
            delay_s = propagation_delay_s,
            capacity_mbps = capacity_mbps,
        )
        for (link_id, (src, dst)) in enumerate(edges)
    ]
    topology = TRAFFIC_AON_LINK.ConstellationTopology("traffic-test", links)
    offsets = timeslot_offsets(grid)
    samples_by_time = [
        [
            ISLPhysicalLinkSample(
                link_id = link_id,
                time_index = time_index,
                elapsed_s = offsets[time_index],
                endpoint_a_id = src,
                endpoint_b_id = dst,
                distance_km = 1000.0,
                propagation_delay_s = propagation_delay_s,
                capacity_mbps = available ? capacity_mbps : 0.0,
                state = available ? LinkAvailable() : LinkUnavailable(),
                line_of_sight = available,
            )
            for (link_id, (src, dst)) in enumerate(edges)
        ]
        for time_index in 1:time_count(grid)
    ]
    return ISLPhysicalLinkSeries(topology, grid, samples_by_time)
end

function traffic_aon_access_table(
    grid::SimulationTimeGrid,
    access_by_ground::Dict{Int,Union{Nothing,Int}},
)::AccessDecisionTable
    decisions_by_ground = Dict{Int,Vector{AccessDecision}}()
    for (ground_id, satellite_id) in access_by_ground
        decisions_by_ground[ground_id] = [
            AccessDecision(
                ground_id = ground_id,
                time_index = time_index,
                selected_satellite_id = satellite_id,
                selected_sample = nothing,
            )
            for time_index in 1:time_count(grid)
        ]
    end
    return AccessDecisionTable(grid, decisions_by_ground)
end

@testset "MinLoad AON splits sequential demands across diamond paths" begin
    grid = traffic_aon_grid()
    edges = Tuple{Int,Int}[(1, 2), (2, 4), (1, 3), (3, 4)]
    isl_series = traffic_aon_isl_series(grid, edges; capacity_mbps = 100.0)
    access_table = traffic_aon_access_table(grid, Dict{Int,Union{Nothing,Int}}(1 => 1, 4 => 4))
    demands = TrafficDemand[
        TrafficDemand(
            id = 1,
            source_ground_id = 1,
            destination_ground_id = 4,
            start_elapsed_s = 0,
            end_elapsed_s = 60,
            rate_mbps = 100.0,
        ),
        TrafficDemand(
            id = 2,
            source_ground_id = 1,
            destination_ground_id = 4,
            start_elapsed_s = 0,
            end_elapsed_s = 60,
            rate_mbps = 100.0,
        ),
    ]

    evaluation = evaluate_traffic(demands, isl_series, access_table, MinLoadRouting())

    @test evaluation isa TrafficEvaluation
    @test evaluation.time_grid === grid
    @test length(evaluation.assignments_by_time[1]) == 2
    @test isempty(evaluation.assignments_by_time[2])
    @test isempty(evaluation.link_loads_by_time[2])

    assignments = evaluation.assignments_by_time[1]
    @test all(assignment -> assignment.route.reachable, assignments)
    @test all(assignment -> assignment.route.reason == :min_load, assignments)
    @test all(
        assignment -> isapprox(
            assignment.offered_mbps,
            assignment.carried_mbps + assignment.dropped_mbps;
            atol = TRAFFIC_AON_ATOL,
        ),
        assignments,
    )
    @test any(assignment -> assignment.route.satellite_path == [1, 2, 4], assignments)
    @test any(assignment -> assignment.route.satellite_path == [1, 3, 4], assignments)

    isl_loads = sort(
        filter(load -> load.link_type == :isl, evaluation.link_loads_by_time[1]);
        by = load -> load.link_id,
    )
    @test length(isl_loads) == 4
    @test [load.link_id for load in isl_loads] == [1, 2, 3, 4]
    @test all(load -> isapprox(load.load_mbps, 100.0; atol = TRAFFIC_AON_ATOL), isl_loads)
    @test all(load -> isapprox(load.capacity_mbps, 100.0; atol = TRAFFIC_AON_ATOL), isl_loads)
    @test all(load -> isapprox(load.utilization, 1.0; atol = TRAFFIC_AON_ATOL), isl_loads)
    @test all(load -> !load.congested, isl_loads)
end

@testset "AON drops demand when destination has no access" begin
    grid = traffic_aon_grid()
    isl_series = traffic_aon_isl_series(grid, Tuple{Int,Int}[(1, 2)])
    access_table = traffic_aon_access_table(grid, Dict{Int,Union{Nothing,Int}}(1 => 1, 2 => nothing))
    demand = TrafficDemand(
        id = 1,
        source_ground_id = 1,
        destination_ground_id = 2,
        start_elapsed_s = 0,
        end_elapsed_s = 60,
        rate_mbps = 100.0,
    )

    evaluation = evaluate_traffic(TrafficDemand[demand], isl_series, access_table)

    @test length(evaluation.assignments_by_time[1]) == 1
    assignment = only(evaluation.assignments_by_time[1])
    @test !assignment.route.reachable
    @test assignment.route.reason == :destination_no_access
    @test isapprox(assignment.offered_mbps, 100.0; atol = TRAFFIC_AON_ATOL)
    @test isapprox(assignment.carried_mbps, 0.0; atol = TRAFFIC_AON_ATOL)
    @test isapprox(assignment.dropped_mbps, 100.0; atol = TRAFFIC_AON_ATOL)
    @test isempty(evaluation.link_loads_by_time[1])
end

@testset "AON drops demand when the only ISL is unavailable" begin
    grid = traffic_aon_grid()
    isl_series = traffic_aon_isl_series(grid, Tuple{Int,Int}[(1, 2)]; available = false)
    access_table = traffic_aon_access_table(grid, Dict{Int,Union{Nothing,Int}}(1 => 1, 2 => 2))
    demand = TrafficDemand(
        id = 1,
        source_ground_id = 1,
        destination_ground_id = 2,
        start_elapsed_s = 0,
        end_elapsed_s = 60,
        rate_mbps = 100.0,
    )

    evaluation = evaluate_traffic(TrafficDemand[demand], isl_series, access_table)

    @test length(evaluation.assignments_by_time[1]) == 1
    assignment = only(evaluation.assignments_by_time[1])
    @test !assignment.route.reachable
    @test assignment.route.reason == :isl_unreachable
    @test assignment.route.source_access_satellite_id == 1
    @test assignment.route.destination_access_satellite_id == 2
    @test isapprox(assignment.offered_mbps, 100.0; atol = TRAFFIC_AON_ATOL)
    @test isapprox(assignment.carried_mbps, 0.0; atol = TRAFFIC_AON_ATOL)
    @test isapprox(assignment.dropped_mbps, 100.0; atol = TRAFFIC_AON_ATOL)
    @test isempty(evaluation.link_loads_by_time[1])
end

@testset "AON rejects algorithms without path semantics" begin
    grid = traffic_aon_grid()
    isl_series = traffic_aon_isl_series(grid, Tuple{Int,Int}[(1, 2)])
    access_table = traffic_aon_access_table(grid, Dict{Int,Union{Nothing,Int}}(1 => 1, 2 => 2))
    demand = TrafficDemand(
        id = 1,
        source_ground_id = 1,
        destination_ground_id = 2,
        start_elapsed_s = 0,
        end_elapsed_s = 60,
        rate_mbps = 100.0,
    )
    fake_pinn = PINNRoutingAlgorithm(nothing, (_, __, ___, ____) -> 1.0)

    @test_throws ArgumentError evaluate_traffic(TrafficDemand[demand], isl_series, access_table, fake_pinn)
    @test_throws ArgumentError evaluate_traffic(TrafficDemand[demand], isl_series, access_table, CGRRouting())
end

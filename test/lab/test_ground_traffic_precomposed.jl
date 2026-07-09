# test/lab/test_ground_traffic_precomposed.jl — Lab 地面端到端动态流量编排回归

using Test

const LAB_GROUND_TRAFFIC_ATOL = 1e-9

struct LabDiamondStrategy <: AbstractTopologyStrategy end

function SatelliteSimNet.generate_topology(::LabDiamondStrategy, T::Int, P::Int)
    return TopologyOutput(Tuple{Int,Int}[], Tuple{Int,Int}[(1, 2), (2, 4), (1, 3), (3, 4)], "lab-diamond")
end

struct LabTimeIndexedStrategy <: AbstractTopologyStrategy
    links_by_time::Vector{Vector{Tuple{Int,Int}}}
    time_index::Int
end

function SatelliteSimNet.generate_topology(strategy::LabTimeIndexedStrategy, T::Int, P::Int)
    return TopologyOutput(Tuple{Int,Int}[], strategy.links_by_time[strategy.time_index], "lab-time-indexed")
end

lab_ground_constraints() = PhysicalConstraints(
    isl_max_range_km = 20000.0,
    isl_require_los = false,
    isl_max_capacity_mbps = 100.0,
    gsl_min_elevation_deg = -90.0,
    gsl_max_range_km = 30000.0,
    gsl_base_capacity_mbps = 500.0,
)

function lab_positions(coords::Vector{NTuple{3,Float64}}, n_time::Int)
    positions = zeros(Float64, length(coords), n_time, 3)
    for t in 1:n_time, (sat_id, coord) in enumerate(coords)
        positions[sat_id, t, 1] = coord[1]
        positions[sat_id, t, 2] = coord[2]
        positions[sat_id, t, 3] = coord[3]
    end
    return positions
end

function lab_diamond_positions(n_time::Int = 2)
    return lab_positions(
        [
            (7000.0, 0.0, 0.0),
            (0.0, 7000.0, 0.0),
            (0.0, -7000.0, 0.0),
            (-7000.0, 0.0, 0.0),
        ],
        n_time,
    )
end

function lab_dynamic_positions(n_time::Int = 2)
    return lab_positions(
        [
            (7000.0, 0.0, 0.0),
            (0.0, 7000.0, 0.0),
            (0.0, -7000.0, 0.0),
        ],
        n_time,
    )
end

@testset "HotspotLoad resolves ground station ids without explicit ground_pairs" begin
    stations = [
        GroundStation(id = 10, name = "source", position = GeodeticPosition(0.0, 0.0, 0.0)),
        GroundStation(id = 20, name = "middle", position = GeodeticPosition(0.0, 90.0, 0.0)),
        GroundStation(id = 30, name = "sink", position = GeodeticPosition(0.0, 180.0, 0.0)),
    ]

    config = ExperimentConfig(
        tspan = [0.0, 60.0],
        traffic = HotspotLoad(),
        ground_stations = stations,
    )

    @test length(config.traffic_demands) == 3
    endpoint_ids = Set(vcat(
        [demand.source_ground_id for demand in config.traffic_demands],
        [demand.destination_ground_id for demand in config.traffic_demands],
    ))
    @test endpoint_ids == Set([10, 20, 30])
    @test any(demand -> isapprox(demand.rate_mbps, 200.0; atol = LAB_GROUND_TRAFFIC_ATOL), config.traffic_demands)
end

@testset "assess_ground_traffic_temporal_dynamic returns TrafficEvaluation with MinLoad split" begin
    positions = lab_diamond_positions()
    stations = [
        GroundStation(id = 1, name = "src", position = GeodeticPosition(0.0, 0.0, 0.0)),
        GroundStation(id = 4, name = "dst", position = GeodeticPosition(0.0, 180.0, 0.0)),
    ]
    demands = TrafficDemand[
        TrafficDemand(id = 1, source_ground_id = 1, destination_ground_id = 4, start_elapsed_s = 0, end_elapsed_s = 60, rate_mbps = 100.0),
        TrafficDemand(id = 2, source_ground_id = 1, destination_ground_id = 4, start_elapsed_s = 0, end_elapsed_s = 60, rate_mbps = 100.0),
    ]

    evaluation = assess_ground_traffic_temporal_dynamic(
        positions,
        4,
        1,
        _ -> LabDiamondStrategy(),
        lab_ground_constraints(),
        stations,
        demands;
        elapsed_by_time = [0, 60],
        routing_algorithm = MinLoadRouting(),
        constellation_name = "lab-minload-diamond",
    )

    @test evaluation isa TrafficEvaluation
    @test length(evaluation.assignments_by_time[1]) == 2
    @test isempty(evaluation.assignments_by_time[2])
    assignments = evaluation.assignments_by_time[1]
    @test all(assignment -> assignment.route.reachable, assignments)
    @test all(assignment -> assignment.route.reason == :min_load, assignments)
    @test Set(Tuple(assignment.route.satellite_path) for assignment in assignments) ==
          Set([(1, 2, 4), (1, 3, 4)])

    isl_loads = filter(load -> load.link_type == :isl, evaluation.link_loads_by_time[1])
    @test length(isl_loads) == 4
    @test all(load -> isapprox(load.load_mbps, 100.0; atol = LAB_GROUND_TRAFFIC_ATOL), isl_loads)
end

@testset "dynamic ground traffic keeps union links unavailable outside each frame" begin
    positions = lab_dynamic_positions()
    stations = [
        GroundStation(id = 1, name = "src", position = GeodeticPosition(0.0, 0.0, 0.0)),
        GroundStation(id = 3, name = "dst", position = GeodeticPosition(0.0, -90.0, 0.0)),
    ]
    demands = TrafficDemand[
        TrafficDemand(id = 1, source_ground_id = 1, destination_ground_id = 3, start_elapsed_s = 0, end_elapsed_s = 120, rate_mbps = 50.0),
    ]
    links_by_time = [Tuple{Int,Int}[(1, 2)], Tuple{Int,Int}[(1, 3)]]

    evaluation = assess_ground_traffic_temporal_dynamic(
        positions,
        3,
        1,
        t -> LabTimeIndexedStrategy(links_by_time, t),
        lab_ground_constraints(),
        stations,
        demands;
        elapsed_by_time = [0, 60],
        routing_algorithm = DijkstraRouting(),
        constellation_name = "lab-dynamic-union",
    )

    first_route = only(evaluation.assignments_by_time[1]).route
    second_route = only(evaluation.assignments_by_time[2]).route

    @test !first_route.reachable
    @test first_route.reason == :isl_unreachable
    @test second_route.reachable
    @test second_route.satellite_path == [1, 3]
    @test second_route.isl_link_ids == [2]
end

@testset "dynamic ground traffic scenario runner returns summary-ready TrafficEvaluation" begin
    positions = lab_diamond_positions()
    stations = [
        GroundStation(id = 1, name = "src", position = GeodeticPosition(0.0, 0.0, 0.0)),
        GroundStation(id = 4, name = "dst", position = GeodeticPosition(0.0, 180.0, 0.0)),
    ]
    config = ExperimentConfig(
        name = "scenario-minload",
        constellation_params = Dict(:T => 4.0, :P => 1.0, :F => 0.0, :alt_km => 550.0, :inc_deg => 0.0),
        tspan = [0.0, 60.0],
        constraints = lab_ground_constraints(),
        topology_strategy = LabDiamondStrategy(),
        routing_algorithm = MinLoadRouting(),
        traffic = HotspotLoad(),
        ground_stations = stations,
    )

    evaluation = run_dynamic_ground_traffic_scenario(
        config;
        positions = positions,
        strategy_builder = _ -> LabDiamondStrategy(),
    )
    summary = traffic_evaluation_summary(evaluation)

    @test evaluation isa TrafficEvaluation
    @test summary.n_assignments == 1
    @test summary.n_reachable == 1
    @test isapprox(summary.carried_mbps, 200.0; atol = LAB_GROUND_TRAFFIC_ATOL)
end

@testset "sweep_ground_traffic scans outer parameters without replacing scenario entry" begin
    positions = lab_diamond_positions()
    stations = [
        GroundStation(id = 1, name = "src", position = GeodeticPosition(0.0, 0.0, 0.0)),
        GroundStation(id = 4, name = "dst", position = GeodeticPosition(0.0, 180.0, 0.0)),
    ]
    demands = TrafficDemand[
        TrafficDemand(id = 1, source_ground_id = 1, destination_ground_id = 4, start_elapsed_s = 0, end_elapsed_s = 60, rate_mbps = 100.0),
    ]
    scenario = pair -> assess_ground_traffic_temporal_dynamic(
        positions,
        4,
        1,
        _ -> LabDiamondStrategy(),
        lab_ground_constraints(),
        stations,
        demands;
        elapsed_by_time = [0, 60],
        routing_algorithm = MinLoadRouting(),
        isl_capacity_mbps = pair.second,
    )

    results = sweep_ground_traffic(scenario, :isl_capacity_mbps, [50.0, 100.0])

    @test length(results) == 2
    @test [result.value for result in results] == [50.0, 100.0]
    @test all(result -> result.evaluation isa TrafficEvaluation, results)
    @test all(result -> result.summary.n_reachable == 1, results)
    @test results[1].summary.max_isl_utilization > results[2].summary.max_isl_utilization
end

@testset "assess_temporal_flow_routes rejects ground endpoint ids" begin
    positions = lab_dynamic_positions()
    demands = TrafficDemand[
        TrafficDemand(id = 1, source_ground_id = 10, destination_ground_id = 1, start_elapsed_s = 0, end_elapsed_s = 60, rate_mbps = 10.0),
    ]

    @test_throws ArgumentError assess_temporal_flow_routes(
        positions,
        3,
        1,
        _ -> LabTimeIndexedStrategy([Tuple{Int,Int}[(1, 2)]], 1),
        lab_ground_constraints(),
        demands,
        DijkstraRouting();
        elapsed_by_time = [0, 60],
    )
end

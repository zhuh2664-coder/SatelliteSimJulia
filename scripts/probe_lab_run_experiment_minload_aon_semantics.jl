#!/usr/bin/env julia

using Test
using SatelliteSimCore
using SatelliteSimLab
using SatelliteSimNet
using SatelliteSimTraffic

struct DiamondTopologyStrategy <: AbstractTopologyStrategy end

function SatelliteSimNet.generate_topology(
    ::DiamondTopologyStrategy,
    T::Int,
    P::Int,
)::TopologyOutput
    T == 4 || throw(ArgumentError("DiamondTopologyStrategy probe expects T=4"))
    return TopologyOutput(
        [(1, 2), (2, 4), (1, 3), (3, 4)],
        Tuple{Int,Int}[],
        "diamond topology probe",
    )
end

function satellite_subpoint_deg(positions::Array{Float64,3}, sat_id::Int)
    x, y, z = positions[sat_id, 1, 1], positions[sat_id, 1, 2], positions[sat_id, 1, 3]
    radius = sqrt(x * x + y * y + z * z)
    return (asind(z / radius), atan(y, x) * 180 / pi)
end

@testset "Lab run_experiment MinLoad AON semantics" begin
    constraints = PhysicalConstraints(
        isl_max_range_km = 50_000.0,
        isl_require_los = false,
        isl_max_capacity_mbps = 100.0,
        gsl_min_elevation_deg = -90.0,
        gsl_max_range_km = 50_000.0,
    )
    base_kwargs = (
        constellation_params = Dict(:T => 4.0, :P => 1.0, :F => 0.0, :alt_km => 550.0, :inc_deg => 53.0),
        tspan = [0.0],
        topology_strategy = DiamondTopologyStrategy(),
        routing_algorithm = MinLoadRouting(),
        constraints = constraints,
    )

    seed_config = ExperimentConfig(; base_kwargs..., traffic = TrafficDemand[])
    _, positions = propagate_constellation_positions(seed_config)
    source_lat, source_lon = satellite_subpoint_deg(positions, 1)
    dest_lat, dest_lon = satellite_subpoint_deg(positions, 4)
    ground_stations = [
        GroundStation(id = 1, name = "source", position = GeodeticPosition(source_lat, source_lon, 0.0)),
        GroundStation(id = 2, name = "destination", position = GeodeticPosition(dest_lat, dest_lon, 0.0)),
    ]
    demands = [
        TrafficDemand(
            id = 1,
            source_ground_id = 1,
            destination_ground_id = 2,
            start_elapsed_s = 0,
            end_elapsed_s = 60,
            rate_mbps = 100.0,
        ),
        TrafficDemand(
            id = 2,
            source_ground_id = 1,
            destination_ground_id = 2,
            start_elapsed_s = 0,
            end_elapsed_s = 60,
            rate_mbps = 100.0,
        ),
    ]

    config = ExperimentConfig(;
        base_kwargs...,
        traffic = demands,
        ground_pairs = [(1, 2)],
        ground_stations = ground_stations,
    )
    result = run_experiment(config)

    @test result.traffic_evaluation isa TrafficEvaluation
    assignments = result.traffic_evaluation.assignments_by_time[1]
    @test length(assignments) == 2
    @test all(assignment -> assignment.route.reachable, assignments)
    @test all(assignment -> assignment.route.reason == :min_load, assignments)
    @test [assignment.route.source_access_satellite_id for assignment in assignments] == [1, 1]
    @test [assignment.route.destination_access_satellite_id for assignment in assignments] == [4, 4]
    @test sort([assignment.route.satellite_path for assignment in assignments]) ==
          sort([[1, 2, 4], [1, 3, 4]])

    isl_loads = [
        load for load in result.traffic_evaluation.link_loads_by_time[1]
        if load.link_type == :isl
    ]
    @test sort([(load.endpoint_a_id, load.endpoint_b_id, load.load_mbps) for load in isl_loads]) ==
          [(1, 2, 100.0), (1, 3, 100.0), (2, 4, 100.0), (3, 4, 100.0)]
    @test all(load -> load.capacity_mbps == 100.0, isl_loads)
    @test all(load -> load.utilization == 1.0, isl_loads)

    @test result.routing_metrics.total_pairs == length(assignments)
    @test result.routing_metrics.routed_pairs == length(assignments)
    @test result.routing_metrics.avg_hop_count == 2.0
    @test result.latency.path_count == length(assignments)
    @test result.network.connectivity_ratio == 1.0
end

println("LAB RUN EXPERIMENT MINLOAD AON SEMANTICS: ALL PASS")

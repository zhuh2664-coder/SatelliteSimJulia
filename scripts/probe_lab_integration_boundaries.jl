#!/usr/bin/env julia

using Test
using SatelliteSimCore
using SatelliteSimLab
using SatelliteSimNet
using SatelliteSimTraffic

function lab_boundary_constraints()
    return PhysicalConstraints(
        isl_max_range_km=12000.0,
        isl_require_los=false,
        gsl_min_elevation_deg=5.0,
        gsl_max_range_km=20000.0,
    )
end

function lab_boundary_ground_stations()
    return [
        GroundStation(id=1, name="beijing", position=GeodeticPosition(39.9042, 116.4074, 0.0)),
        GroundStation(id=2, name="singapore", position=GeodeticPosition(1.3521, 103.8198, 0.0)),
    ]
end

const LAB_COMMON = (
    constellation_params=Dict(:T=>24.0, :P=>6.0, :F=>1.0, :alt_km=>550.0, :inc_deg=>53.0),
    tspan=collect(0.0:60.0:120.0),
    topology_strategy=GridPlusStrategy(),
    routing_algorithm=DijkstraRouting(),
    constraints=lab_boundary_constraints(),
)

@testset "Lab integration boundaries" begin
    @testset "Traffic intent needs both demands and ground stations for full AON" begin
        no_pairs = ExperimentConfig(; LAB_COMMON..., traffic=:uniform)
        no_pairs_result = run_experiment(no_pairs)

        @test isempty(no_pairs.traffic_demands)
        @test no_pairs_result.traffic_evaluation === nothing

        pairs_only = ExperimentConfig(; LAB_COMMON..., traffic=:uniform, ground_pairs=[(1, 2)])
        pairs_only_result = run_experiment(pairs_only)

        @test length(pairs_only.traffic_demands) == 1
        @test pairs_only_result.traffic_evaluation === nothing
        @test isfinite(pairs_only_result.utilization.avg_utilization)

        full_aon = ExperimentConfig(;
            LAB_COMMON...,
            traffic=:uniform,
            ground_pairs=[(1, 2)],
            ground_stations=lab_boundary_ground_stations(),
        )
        full_aon_result = run_experiment(full_aon)

        @test length(full_aon.traffic_demands) == 1
        @test full_aon_result.traffic_evaluation isa TrafficEvaluation
        @test length(full_aon_result.traffic_evaluation.assignments_by_time) == length(full_aon.tspan)
        @test length(full_aon_result.traffic_evaluation.link_loads_by_time) == length(full_aon.tspan)

        min_load_full_aon = ExperimentConfig(;
            LAB_COMMON...,
            routing_algorithm=MinLoadRouting(),
            traffic=:uniform,
            ground_pairs=[(1, 2)],
            ground_stations=lab_boundary_ground_stations(),
        )
        min_load_result = run_experiment(min_load_full_aon)
        min_load_assignments = vcat(min_load_result.traffic_evaluation.assignments_by_time...)

        @test min_load_result.traffic_evaluation isa TrafficEvaluation
        @test any(
            assignment -> assignment.route.reachable && assignment.route.reason == :min_load,
            min_load_assignments,
        )
        @test min_load_result.routing_metrics.total_pairs == length(min_load_assignments)
        @test min_load_result.routing_metrics.routed_pairs ==
              count(assignment -> assignment.route.reachable, min_load_assignments)
        @test min_load_result.latency.path_count == min_load_result.routing_metrics.routed_pairs
        @test min_load_result.latency.samples_ms == sort([
            1000.0 * assignment.route.total_delay_s
            for assignment in min_load_assignments
            if assignment.route.reachable
        ])
        reachable_count = count(assignment -> assignment.route.reachable, min_load_assignments)
        @test min_load_result.network.connectivity_ratio == reachable_count / length(min_load_assignments)
        @test min_load_result.network.is_connected == (reachable_count == length(min_load_assignments))
        if !isempty(min_load_result.latency.samples_ms)
            @test min_load_result.network.diameter == maximum(min_load_result.latency.samples_ms)
            @test min_load_result.network.avg_path_length ==
                  sum(min_load_result.latency.samples_ms) / length(min_load_result.latency.samples_ms)
        end
    end

    @testset "Routing algorithm is currently a Lab intent label" begin
        base = (
            constellation_params=Dict(:T=>48.0, :P=>8.0, :F=>1.0, :alt_km=>550.0, :inc_deg=>53.0),
            tspan=[0.0, 60.0],
            topology_strategy=GridPlusStrategy(),
            ground_pairs=[(1, 25), (2, 26), (3, 27)],
            traffic=TrafficDemand[],
        )

        results = Dict{Symbol,ExperimentResult}()
        for (name, alg) in (
            :dijkstra => DijkstraRouting(),
            :ecmp => ECMPRouting(),
            :min_load => MinLoadRouting(),
        )
            results[name] = run_experiment(ExperimentConfig(; base..., routing_algorithm=alg))
        end

        dijkstra = results[:dijkstra]
        for result in values(results)
            @test result.routing_metrics == dijkstra.routing_metrics
            @test result.network == dijkstra.network
            @test result.fitness == dijkstra.fitness
            @test result.latency.avg_latency_ms == dijkstra.latency.avg_latency_ms
            @test result.latency.max_latency_ms == dijkstra.latency.max_latency_ms
            @test result.latency.min_latency_ms == dijkstra.latency.min_latency_ms
            @test result.latency.path_count == dijkstra.latency.path_count
        end
    end
end

println("LAB INTEGRATION BOUNDARIES: ALL PASS")

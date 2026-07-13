using Test
using SatelliteSimBackends
using SatelliteSimCore
using SatelliteSimFoundation
using SatelliteSimJuliaSpaceBackend
using SatelliteSimLab
using SatelliteSimNet
using SatelliteSimStubBackend
using SatelliteSimTraffic

const BACKEND_TSPAN = [0.0, 60.0, 120.0]
const BACKEND_CONSTRAINTS = PhysicalConstraints(
    isl_max_range_km = 1.0e9,
    isl_require_los = false,
    isl_max_capacity_mbps = 1000.0,
    gsl_min_elevation_deg = -90.0,
    gsl_max_range_km = 1.0e9,
    gsl_base_capacity_mbps = 500.0,
)

function backend_config(; name, orbit_backend=nothing, tspan=BACKEND_TSPAN,
                        ground_stations=GroundStation[], traffic=TrafficDemand[])
    return ExperimentConfig(
        name = name,
        constellation_params = Dict(
            :T => 6.0,
            :P => 3.0,
            :F => 1.0,
            :alt_km => 550.0,
            :inc_deg => 53.0,
        ),
        tspan = Float64.(tspan),
        propagator = :two_body,
        orbit_backend = orbit_backend,
        topology_strategy = GridPlusStrategy(),
        routing_algorithm = DijkstraRouting(),
        constraints = BACKEND_CONSTRAINTS,
        traffic = traffic,
        ground_stations = ground_stations,
        users = [
            GroundUser("equator", 0.0, 0.0, 10.0, 10.0, "integration"),
            GroundUser("midlat", 35.0, 120.0, 10.0, 10.0, "integration"),
        ],
    )
end

function subpoint_station(id::Int, name::String, positions, sat_id::Int, time_index::Int=1)
    x = Float64(positions[sat_id, time_index, 1])
    y = Float64(positions[sat_id, time_index, 2])
    z = Float64(positions[sat_id, time_index, 3])
    latitude_deg = atan(z, hypot(x, y)) * 180 / pi
    longitude_deg = atan(y, x) * 180 / pi
    return GroundStation(id, name, GeodeticPosition(latitude_deg, longitude_deg, 0.0))
end

function configured_experiment(name::Symbol, orbit_backend)
    probe = backend_config(name="$(name)-probe", orbit_backend=orbit_backend)
    _, positions = propagate_constellation_positions(probe)
    stations = GroundStation[
        subpoint_station(1, "source", positions, 1),
        subpoint_station(2, "destination", positions, 4),
    ]
    demand = TrafficDemand(
        id = 1,
        source_ground_id = 1,
        destination_ground_id = 2,
        start_elapsed_s = 0,
        end_elapsed_s = 121,
        rate_mbps = 25.0,
    )
    return backend_config(
        name = "$(name)-high-level",
        orbit_backend = orbit_backend,
        ground_stations = stations,
        traffic = TrafficDemand[demand],
    )
end

coverage_summary(result) = (
    result.coverage_ratio,
    result.covered_users,
    result.total_users,
)

function traffic_summary(evaluation::TrafficEvaluation)
    assignments = [
        (
            a.demand_id,
            a.time_index,
            a.elapsed_s,
            a.route.source_access_satellite_id,
            a.route.destination_access_satellite_id,
            a.route.satellite_path,
            a.route.isl_link_ids,
            a.route.isl_delay_s,
            a.route.source_gsl_delay_s,
            a.route.destination_gsl_delay_s,
            a.route.total_delay_s,
            a.route.reachable,
            a.route.reason,
            a.offered_mbps,
            a.carried_mbps,
            a.dropped_mbps,
        )
        for frame in evaluation.assignments_by_time for a in frame
    ]
    loads = [
        (
            l.link_type,
            l.link_id,
            l.endpoint_a_id,
            l.endpoint_b_id,
            l.time_index,
            l.elapsed_s,
            l.load_mbps,
            l.capacity_mbps,
            l.utilization,
            l.congested,
        )
        for frame in evaluation.link_loads_by_time for l in frame
    ]
    return assignments, loads
end

@testset "three orbit implementations share the Lab experiment entry" begin
    @test orbit_backend_registered(:stub)
    @test orbit_backend_registered(:julia_space)

    selections = (
        native = nothing,
        stub = OrbitBackendSpec(:stub),
        julia_space = OrbitBackendSpec(:julia_space; propagator=:two_body),
    )

    for (name, selection) in pairs(selections)
        config = configured_experiment(name, selection)
        result = run_experiment(config)
        @test result isa ExperimentResult
        @test result.config.orbit_backend == selection
        @test result.coverage.total_users == 2
        @test isfinite(result.coverage.coverage_ratio)
        @test result.traffic_evaluation isa TrafficEvaluation
        @test length(result.traffic_evaluation.assignments_by_time) == length(BACKEND_TSPAN)
        @test all(length(frame) == 1 for frame in result.traffic_evaluation.assignments_by_time)
        @test all(first(frame).route.reachable for frame in result.traffic_evaluation.assignments_by_time)

        _, positions = propagate_constellation_positions(config)
        @test size(positions) == (6, 3, 3)
        gsl_available, _ = assess_coverage(positions, config.ground_endpoints, config.constraints)
        D, available_isl, isl_results = assess_routing(
            positions, 6, 3, config.topology_strategy, config.constraints,
        )
        @test size(gsl_available) == (6, 2)
        @test size(D) == (6, 6)
        @test !isempty(available_isl)
        @test length(isl_results) >= length(available_isl)
    end
end

@testset "Array and SubArray are equivalent through GSL, ISL, routing, and Traffic" begin
    selections = (
        native = nothing,
        stub = OrbitBackendSpec(:stub),
        julia_space = OrbitBackendSpec(:julia_space; propagator=:two_body),
    )

    for (name, selection) in pairs(selections)
        padded = backend_config(
            name = "$(name)-subarray",
            orbit_backend = selection,
            tspan = [0.0, 60.0, 120.0, 180.0],
        )
        _, all_positions = propagate_constellation_positions(padded)
        positions_view = @view all_positions[:, 1:3, :]
        positions_array = Array(positions_view)
        @test positions_view isa SubArray

        view_gsl, view_coverage = assess_coverage(
            positions_view, padded.ground_endpoints, padded.constraints,
        )
        array_gsl, array_coverage = assess_coverage(
            positions_array, padded.ground_endpoints, padded.constraints,
        )
        @test view_gsl == array_gsl
        @test coverage_summary(view_coverage) == coverage_summary(array_coverage)

        view_D, view_available, view_isl = assess_routing(
            positions_view, 6, 3, padded.topology_strategy, padded.constraints,
        )
        array_D, array_available, array_isl = assess_routing(
            positions_array, 6, 3, padded.topology_strategy, padded.constraints,
        )
        @test isequal(view_D, array_D)
        @test view_available == array_available
        @test view_isl == array_isl

        stations = GroundStation[
            subpoint_station(1, "source", positions_view, 1),
            subpoint_station(2, "destination", positions_view, 4),
        ]
        demands = TrafficDemand[TrafficDemand(
            id = 1,
            source_ground_id = 1,
            destination_ground_id = 2,
            start_elapsed_s = 0,
            end_elapsed_s = 121,
            rate_mbps = 25.0,
        )]
        strategy_builder = _ -> GridPlusStrategy()
        view_traffic = assess_ground_traffic_temporal_dynamic(
            positions_view, 6, 3, strategy_builder, padded.constraints, stations, demands;
            elapsed_by_time = BACKEND_TSPAN,
            routing_algorithm = DijkstraRouting(),
        )
        array_traffic = assess_ground_traffic_temporal_dynamic(
            positions_array, 6, 3, strategy_builder, padded.constraints, stations, demands;
            elapsed_by_time = BACKEND_TSPAN,
            routing_algorithm = DijkstraRouting(),
        )
        @test traffic_summary(view_traffic) == traffic_summary(array_traffic)
    end
end

@testset "native and JuliaSpace adapter cross-implementation error" begin
    elements = generate_walker_delta(T=12, P=3, F=1, alt_km=550.0, inc_deg=71.0)
    times = [0.0, 17.0, 60.0, 600.0]
    for propagator in (:two_body, :j2, :j4)
        native = propagate_to_ecef(elements, times; propagator=propagator)
        backend = create_orbit_backend(:julia_space; propagator=propagator)
        adapter_result = propagate_orbit(backend, elements, times)
        @test backend_capabilities(backend).implementation == :independent_secular_elements
        @test adapter_result.metadata["implementation"] == "independent_secular_elements"
        adapter = adapter_result.positions_ecef_km
        max_error_km = maximum(abs.(native .- adapter))
        @test max_error_km <= 1e-3
    end
end

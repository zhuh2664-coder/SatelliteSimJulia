# test/net/test_core_routing_paths.jl — 接入决策与端到端路由回归测试

using SatelliteSimJulia
using Test

const CORE_ROUTING_LINK = SatelliteSimJulia.SatelliteSimCore.SatelliteSimLink
const CORE_ROUTING_ATOL = 1e-9

core_routing_grid() = SimulationTimeGrid(default_starlink_simulation_epoch(), 60, 60)

function core_routing_gsl_sample(
    ground_id::Int,
    satellite_id::Int,
    time_index::Int,
    elapsed_s::Int;
    delay_s::Float64 = 0.1,
    elevation_deg::Float64 = 45.0,
    capacity_mbps::Float64 = 500.0,
    state = LinkAvailable(),
)::GSLPhysicalLinkSample
    return GSLPhysicalLinkSample(
        ground_id = ground_id,
        satellite_id = satellite_id,
        time_index = time_index,
        elapsed_s = elapsed_s,
        distance_km = delay_s * 299792.458,
        propagation_delay_s = delay_s,
        elevation_deg = elevation_deg,
        capacity_mbps = capacity_mbps,
        state = state,
    )
end

function core_routing_isl_series(
    grid::SimulationTimeGrid,
    edges::Vector{Tuple{Int,Int}};
    delays_s::Vector{Float64},
    available_by_time::Vector{Vector{Bool}} = [fill(true, length(edges)) for _ in 1:time_count(grid)],
)::ISLPhysicalLinkSeries
    links = [
        CORE_ROUTING_LINK.SatelliteLink(
            id = link_id,
            endpoint_a = CORE_ROUTING_LINK.LinkEndpoint(src),
            endpoint_b = CORE_ROUTING_LINK.LinkEndpoint(dst),
            delay_s = delays_s[link_id],
            capacity_mbps = 1000.0,
        )
        for (link_id, (src, dst)) in enumerate(edges)
    ]
    topology = CORE_ROUTING_LINK.ConstellationTopology("routing-test", links)
    offsets = timeslot_offsets(grid)
    samples_by_time = [
        [
            ISLPhysicalLinkSample(
                link_id = link_id,
                time_index = time_index,
                elapsed_s = offsets[time_index],
                endpoint_a_id = src,
                endpoint_b_id = dst,
                distance_km = delays_s[link_id] * 299792.458,
                propagation_delay_s = delays_s[link_id],
                capacity_mbps = available_by_time[time_index][link_id] ? 1000.0 : 0.0,
                state = available_by_time[time_index][link_id] ? LinkAvailable() : LinkUnavailable(),
                line_of_sight = available_by_time[time_index][link_id],
            )
            for (link_id, (src, dst)) in enumerate(edges)
        ]
        for time_index in 1:time_count(grid)
    ]
    return ISLPhysicalLinkSeries(topology, grid, samples_by_time)
end

function core_routing_access_table(
    grid::SimulationTimeGrid,
    access_by_ground::Dict{Int,Union{Nothing,Int}};
    delay_by_ground::Dict{Int,Float64} = Dict{Int,Float64}(),
)::AccessDecisionTable
    offsets = timeslot_offsets(grid)
    decisions_by_ground = Dict{Int,Vector{AccessDecision}}()
    for (ground_id, satellite_id) in access_by_ground
        decisions_by_ground[ground_id] = [
            begin
                sample = satellite_id === nothing ? nothing : core_routing_gsl_sample(
                    ground_id,
                    satellite_id,
                    time_index,
                    offsets[time_index];
                    delay_s = get(delay_by_ground, ground_id, 0.1),
                )
                AccessDecision(
                    ground_id = ground_id,
                    time_index = time_index,
                    selected_satellite_id = satellite_id,
                    selected_sample = sample,
                )
            end
            for time_index in 1:time_count(grid)
        ]
    end
    return AccessDecisionTable(grid, decisions_by_ground)
end

@testset "AccessDecisionTable validates samples and fallback semantics" begin
    grid = core_routing_grid()
    sample = core_routing_gsl_sample(20, 2, 1, 0)

    decision = AccessDecision(
        ground_id = 20,
        time_index = 1,
        selected_satellite_id = 2,
        selected_sample = sample,
    )
    @test decision.selected_satellite_id == 2
    @test decision.selected_sample === sample

    @test_throws ArgumentError AccessDecision(ground_id = 0, time_index = 1, selected_satellite_id = 1, selected_sample = nothing)
    @test_throws ArgumentError AccessDecision(ground_id = 20, time_index = 0, selected_satellite_id = 1, selected_sample = nothing)
    @test_throws ArgumentError AccessDecision(ground_id = 20, time_index = 1, selected_satellite_id = 0, selected_sample = nothing)
    @test_throws ArgumentError AccessDecision(ground_id = 21, time_index = 1, selected_satellite_id = 2, selected_sample = sample)
    @test_throws ArgumentError AccessDecision(ground_id = 20, time_index = 2, selected_satellite_id = 2, selected_sample = sample)
    @test_throws ArgumentError AccessDecision(ground_id = 20, time_index = 1, selected_satellite_id = 3, selected_sample = sample)

    table = core_routing_access_table(grid, Dict{Int,Union{Nothing,Int}}(20 => 2, 10 => 1))
    @test ground_ids(table) == [10, 20]
    @test access_decisions_at(table, 10, 1).selected_satellite_id == 1
    @test access_decisions_at(table, 99, 1).selected_satellite_id === nothing
    @test access_decisions_for_ground(table, 99) == AccessDecision[]

    short_decisions = Dict(1 => [AccessDecision(ground_id = 1, time_index = 1, selected_satellite_id = nothing, selected_sample = nothing)])
    @test_throws ArgumentError AccessDecisionTable(grid, short_decisions)

    wrong_key = Dict(2 => [
        AccessDecision(ground_id = 1, time_index = 1, selected_satellite_id = nothing, selected_sample = nothing),
        AccessDecision(ground_id = 1, time_index = 2, selected_satellite_id = nothing, selected_sample = nothing),
    ])
    @test_throws ArgumentError AccessDecisionTable(grid, wrong_key)
end

@testset "ISL adjacency and shortest path use only available links" begin
    grid = core_routing_grid()
    edges = Tuple{Int,Int}[(1, 2), (2, 3), (1, 3)]
    delays = [1.0, 1.0, 10.0]
    available_by_time = [
        [true, true, false],
        [false, true, true],
    ]
    isl_series = core_routing_isl_series(grid, edges; delays_s = delays, available_by_time = available_by_time)

    adjacency_t1 = available_isl_adjacency(isl_series, 1)
    @test sort(adjacency_t1[1]) == [(2, 1, 1.0)]
    @test sort(adjacency_t1[2]) == [(1, 1, 1.0), (3, 2, 1.0)]
    @test sort(adjacency_t1[3]) == [(2, 2, 1.0)]

    path_t1 = shortest_isl_path(isl_series, 1, 1, 3)
    @test path_t1 !== nothing
    @test path_t1[1] == [1, 2, 3]
    @test path_t1[2] == [1, 2]
    @test isapprox(path_t1[3], 2.0; atol = CORE_ROUTING_ATOL)

    same = shortest_isl_path(isl_series, 1, 2, 2)
    @test same == ([2], Int[], 0.0)

    @test shortest_isl_path(isl_series, 2, 1, 4) === nothing
    @test_throws ArgumentError shortest_isl_path(isl_series, 1, 0, 2)
    @test_throws ArgumentError shortest_isl_path(isl_series, 1, 1, 0)
end

@testset "route_path_at composes access and ISL delays" begin
    grid = core_routing_grid()
    isl_series = core_routing_isl_series(
        grid,
        Tuple{Int,Int}[(1, 2), (2, 3), (1, 3)];
        delays_s = [1.0, 1.0, 10.0],
    )
    access_table = core_routing_access_table(
        grid,
        Dict{Int,Union{Nothing,Int}}(10 => 1, 20 => 3);
        delay_by_ground = Dict(10 => 0.2, 20 => 0.3),
    )

    route_path = route_path_at(RouteRequest(10, 20), isl_series, access_table, 1)

    @test route_path.reachable
    @test route_path.reason == :shortest_delay
    @test route_path.source_access_satellite_id == 1
    @test route_path.destination_access_satellite_id == 3
    @test route_path.satellite_path == [1, 2, 3]
    @test route_path.isl_link_ids == [1, 2]
    @test isapprox(route_path.isl_delay_s, 2.0; atol = CORE_ROUTING_ATOL)
    @test isapprox(route_path.source_gsl_delay_s, 0.2; atol = CORE_ROUTING_ATOL)
    @test isapprox(route_path.destination_gsl_delay_s, 0.3; atol = CORE_ROUTING_ATOL)
    @test isapprox(route_path.total_delay_s, 2.5; atol = CORE_ROUTING_ATOL)

    same_access = core_routing_access_table(
        grid,
        Dict{Int,Union{Nothing,Int}}(10 => 1, 20 => 1);
        delay_by_ground = Dict(10 => 0.2, 20 => 0.3),
    )
    same_path = route_path_at(RouteRequest(10, 20), isl_series, same_access, 1)
    @test same_path.reachable
    @test same_path.reason == :shortest_delay
    @test same_path.satellite_path == [1]
    @test isempty(same_path.isl_link_ids)
    @test isapprox(same_path.total_delay_s, 0.5; atol = CORE_ROUTING_ATOL)

    no_source = route_path_at(RouteRequest(99, 20), isl_series, access_table, 1)
    @test !no_source.reachable
    @test no_source.reason == :source_no_access

    no_destination = route_path_at(RouteRequest(10, 99), isl_series, access_table, 1)
    @test !no_destination.reachable
    @test no_destination.reason == :destination_no_access

    disconnected = core_routing_isl_series(
        grid,
        Tuple{Int,Int}[(1, 2)];
        delays_s = [1.0],
    )
    unreachable = route_path_at(RouteRequest(10, 20), disconnected, access_table, 1)
    @test !unreachable.reachable
    @test unreachable.reason == :isl_unreachable

    other_grid_access = core_routing_access_table(
        SimulationTimeGrid(default_starlink_simulation_epoch(), 60, 60),
        Dict{Int,Union{Nothing,Int}}(10 => 1, 20 => 3),
    )
    @test_throws ArgumentError route_path_at(RouteRequest(10, 20), isl_series, other_grid_access, 1)
end

@testset "route_series filters reachable paths across time" begin
    grid = core_routing_grid()
    available_by_time = [[true], [false]]
    isl_series = core_routing_isl_series(
        grid,
        Tuple{Int,Int}[(1, 2)];
        delays_s = [1.0],
        available_by_time = available_by_time,
    )
    access_table = core_routing_access_table(grid, Dict{Int,Union{Nothing,Int}}(10 => 1, 20 => 2))
    request = RouteRequest(10, 20)

    series = route_series(request, isl_series, access_table)

    @test length(series.paths) == time_count(grid)
    @test route_at(series, 1).reachable
    @test !route_at(series, 2).reachable
    @test length(reachable_routes(series)) == 1
    @test reachable_routes(series)[1].time_index == 1
end

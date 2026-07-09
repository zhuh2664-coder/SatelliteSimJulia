# test/net/test_routing.jl — 统一路由接口测试

using SatelliteSimNet
using Graphs
using Test

"""
    make_routing_graph(N, edges, weights)

用显式边权构造 `RoutingGraph`。
"""
function make_routing_graph(
    N::Int,
    edges::Vector{Tuple{Int,Int}},
    weights::Vector{Float64},
)::RoutingGraph
    adj = Dict{Int,Vector{Tuple{Int,Float64}}}()
    g = SimpleDiGraph(N)
    for (k, (u, v)) in enumerate(edges)
        add_edge!(g, u, v)
        push!(get!(adj, u, Tuple{Int,Float64}[]), (v, weights[k]))
    end
    return RoutingGraph(N, adj, ["$i" for i in 1:N], g)
end

@testset "RoutingGraph construction" begin
    rg = make_routing_graph(3, [(1, 2), (2, 3)], [1.0, 2.0])
    @test rg.n_nodes == 3
    @test haskey(rg.adj, 1)
    @test rg.adj[1][1] == (2, 1.0)
end

@testset "DijkstraRouting" begin
    # 1 -> 2 -> 3 (cost 1+2=3)  vs  1 -> 3 (cost 10)
    rg = make_routing_graph(
        3,
        [(1, 2), (2, 3), (1, 3)],
        [1.0, 2.0, 10.0],
    )

    out = route(DijkstraRouting(), RoutingInput(rg, 1, 3))
    @test out isa RoutingOutput
    @test out.path == [1, 2, 3]
    @test isapprox(out.total_weight, 3.0; atol=1e-9)
    @test out.algorithm == "Dijkstra"

    # 不可达
    out_fail = route(DijkstraRouting(), RoutingInput(rg, 3, 1))
    @test isempty(out_fail.path)
    @test out_fail.total_weight == Inf
    @test occursin("unreachable", out_fail.algorithm)
end

@testset "RoutingOutput total_weight preserves input weight units" begin
    seconds_graph = make_routing_graph(3, [(1, 2), (2, 3)], [0.001, 0.002])
    seconds_out = route(DijkstraRouting(), RoutingInput(seconds_graph, 1, 3))
    @test isapprox(seconds_out.total_weight, 0.003; atol=1e-12)

    milliseconds_graph = make_routing_graph(3, [(1, 2), (2, 3)], [1.0, 2.0])
    milliseconds_out = route(DijkstraRouting(), RoutingInput(milliseconds_graph, 1, 3))
    @test isapprox(milliseconds_out.total_weight, 3.0; atol=1e-12)
end

@testset "ECMPRouting" begin
    # 两条等价最短路径：1->2->4 与 1->3->4，权重和均为 2.0
    rg = make_routing_graph(
        4,
        [(1, 2), (2, 4), (1, 3), (3, 4), (1, 4)],
        [1.0, 1.0, 1.0, 1.0, 10.0],
    )

    out = route(ECMPRouting(), RoutingInput(rg, 1, 4))
    @test out isa RoutingOutput
    @test out.path == [1, 2, 4] || out.path == [1, 3, 4]
    @test isapprox(out.total_weight, 2.0; atol=1e-9)
    @test out.algorithm == "ECMP"

    # 节点 5 与其他节点无连接，真正不可达
    rg2 = make_routing_graph(5, [(1, 2), (2, 4), (1, 3), (3, 4)], [1.0, 1.0, 1.0, 1.0])
    out_fail = route(ECMPRouting(), RoutingInput(rg2, 1, 5))
    @test isempty(out_fail.path)
    @test out_fail.total_weight == Inf
    @test out_fail.algorithm == "ECMP-unreachable"

    same = route(ECMPRouting(), RoutingInput(rg, 2, 2))
    @test same.path == [2]
    @test same.total_weight == 0.0
    @test same.algorithm == "ECMP"
end

@testset "ecmp_paths helper boundaries" begin
    edges = Tuple{Int,Int}[(1, 2), (2, 4), (1, 3), (3, 4), (1, 4)]
    weights = [1.0, 1.0, 1.0, 1.0, 3.0]

    paths = ecmp_paths(4, edges, weights, 1, 4; K=10)
    @test length(paths) == 2
    @test [1, 2, 4] in paths
    @test [1, 3, 4] in paths
    @test !([1, 4] in paths)

    @test isempty(ecmp_paths(5, edges, weights, 1, 5; K=10))
    @test ecmp_paths(4, edges, weights, 1, 4; K=1) == [[1, 2, 4]]

    within_tolerance = ecmp_paths(4, edges, [1.0, 1.0, 1.0, 1.0 + 5e-10, 3.0], 1, 4; K=10)
    @test length(within_tolerance) == 2

    outside_tolerance = ecmp_paths(4, edges, [1.0, 1.0, 1.0, 1.0 + 2e-9, 3.0], 1, 4; K=10)
    @test outside_tolerance == [[1, 2, 4]]
end

@testset "MinLoadRouting" begin
    # 同 Dijkstra 场景，无负载时退化为最短路径
    rg = make_routing_graph(
        3,
        [(1, 2), (2, 3), (1, 3)],
        [1.0, 2.0, 10.0],
    )

    out = route(MinLoadRouting(), RoutingInput(rg, 1, 3))
    @test out isa RoutingOutput
    @test out.path == [1, 2, 3]
    @test isapprox(out.total_weight, 3.0; atol=1e-9)
    @test out.algorithm == "MinLoad"

    same = route(MinLoadRouting(), RoutingInput(rg, 2, 2))
    @test same.path == [2]
    @test same.total_weight == 0.0
    @test same.algorithm == "MinLoad"

    rg2 = make_routing_graph(4, [(1, 2)], [1.0])
    out_fail = route(MinLoadRouting(), RoutingInput(rg2, 1, 4))
    @test isempty(out_fail.path)
    @test out_fail.total_weight == Inf
    @test out_fail.algorithm == "MinLoad-unreachable"
end

@testset "min_load_path helper boundaries" begin
    edges = Tuple{Int,Int}[(1, 2), (2, 4), (1, 3), (3, 4)]
    weights = [1.0, 1.0, 1.0, 1.0]
    capacities = [10.0, 10.0, 10.0, 10.0]

    loaded_path = min_load_path(4, edges, weights, 1, 4, [10.0, 10.0, 0.0, 0.0], capacities)
    @test loaded_path == [1, 3, 4]

    tied_path = min_load_path(4, edges, weights, 1, 4, zeros(4), capacities)
    @test tied_path == [1, 2, 4] || tied_path == [1, 3, 4]

    @test isempty(min_load_path(4, Tuple{Int,Int}[(1, 2)], [1.0], 1, 4, [0.0], [10.0]))

    near_zero_capacity_path = min_load_path(4, edges, weights, 1, 4, [10.0, 0.0, 0.0, 0.0], [0.0, 10.0, 10.0, 10.0])
    @test near_zero_capacity_path == [1, 3, 4]
end

@testset "batch_route" begin
    rg = make_routing_graph(
        3,
        [(1, 2), (2, 3)],
        [1.0, 2.0],
    )

    pairs = [(1, 3), (3, 1)]
    outs = batch_route(DijkstraRouting(), rg, pairs)
    @test length(outs) == 2
    @test outs[1].path == [1, 2, 3]
    @test isempty(outs[2].path)
end

@testset "CGRRouting via AbstractRoutingAlgorithm" begin
    cp = CGRContactPlan("cgr-interface")
    add_contact!(cp, UInt32(1), UInt32(2), 0.0, 10.0, 0.001)
    add_contact!(cp, UInt32(2), UInt32(3), 0.0, 10.0, 0.001)

    out = route(CGRRouting(), cp, 1, 3, 0.0)
    @test out isa RoutingOutput
    @test out.path == [1, 2, 3]
    @test isfinite(out.total_weight)
    @test out.algorithm == "CGR"

    out_fail = route(CGRRouting(), cp, 1, 99, 0.0)
    @test isempty(out_fail.path)
    @test out_fail.total_weight == Inf
end

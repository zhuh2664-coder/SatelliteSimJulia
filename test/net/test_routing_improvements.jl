# test/net/test_routing_improvements.jl — net 层路由改进回归测试
#
# 覆盖两处改进：
#   B2) shortest_isl_path 改用二叉堆（DataStructures.PriorityQueue）后的正确性
#   A1) PINNRoutingAlgorithm.route 现在返回重建后的具体路径（此前恒为空）

using SatelliteSimJulia
using SatelliteSimNet
using Graphs
using Test

# 拓扑契约类型经 Core 透传的 Link 模块访问（与 test_core_routing_paths.jl 一致）
const RIMP_LINK = SatelliteSimJulia.SatelliteSimCore.SatelliteSimLink
const RIMP_C_KM_S = 299792.458

# 菱形 ISL 时序：1-2(L1),1-3(L2),2-4(L3),3-4(L4),2-3(L5)
function rimp_isl_series(
    grid::SimulationTimeGrid,
    edges::Vector{Tuple{Int,Int}},
    delays_s::Vector{Float64},
    available_by_time::Vector{Vector{Bool}},
)::ISLPhysicalLinkSeries
    links = [
        RIMP_LINK.SatelliteLink(
            id = link_id,
            endpoint_a = RIMP_LINK.LinkEndpoint(src),
            endpoint_b = RIMP_LINK.LinkEndpoint(dst),
            delay_s = delays_s[link_id],
            capacity_mbps = 1000.0,
        )
        for (link_id, (src, dst)) in enumerate(edges)
    ]
    topology = RIMP_LINK.ConstellationTopology("routing-improve-test", links)
    offsets = timeslot_offsets(grid)
    samples_by_time = [
        [
            ISLPhysicalLinkSample(
                link_id = link_id,
                time_index = time_index,
                elapsed_s = offsets[time_index],
                endpoint_a_id = src,
                endpoint_b_id = dst,
                distance_km = delays_s[link_id] * RIMP_C_KM_S,
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

function rimp_routing_graph(
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

@testset "net routing improvements" begin
    grid = SimulationTimeGrid(default_starlink_simulation_epoch(), 60, 60)
    edges = [(1, 2), (1, 3), (2, 4), (3, 4), (2, 3)]
    delays = [1.0, 4.0, 1.0, 1.0, 1.0]
    nt = time_count(grid)
    all_up = [fill(true, length(edges)) for _ in 1:nt]
    # 末时刻：把通向节点 4 的 L3/L4 置为不可用（4 不可达）
    node4_down = [copy(fill(true, length(edges))) for _ in 1:nt]
    node4_down[nt][3] = false
    node4_down[nt][4] = false

    @testset "B2: 堆版 Dijkstra 最短路正确" begin
        series = rimp_isl_series(grid, edges, delays, all_up)
        # 1→4 最短：1-2-4，时延 1+1=2（优于 1-3-4=5、1-2-3-4=3）
        result = shortest_isl_path(series, 1, 1, 4)
        @test result !== nothing
        sat_path, link_path, delay = result
        @test sat_path == [1, 2, 4]
        @test link_path == [1, 3]
        @test delay ≈ 2.0
    end

    @testset "B2: 源=目标返回单节点零时延" begin
        series = rimp_isl_series(grid, edges, delays, all_up)
        @test shortest_isl_path(series, 1, 2, 2) == ([2], Int[], 0.0)
    end

    @testset "B2: 不连通返回 nothing" begin
        series = rimp_isl_series(grid, edges, delays, node4_down)
        @test shortest_isl_path(series, nt, 1, 4) === nothing
    end

    @testset "A1: PINN 路由返回重建路径 + 预测时延" begin
        # 1→2(1),2→3(1),1→3(5)：最短路径 [1,2,3]
        graph = rimp_routing_graph(3, [(1, 2), (2, 3), (1, 3)], [1.0, 1.0, 5.0])
        mock_predict(_pinn, _adj, _s, _d) = 42.0   # PINN 预测固定 42ms
        alg = PINNRoutingAlgorithm(nothing, mock_predict)

        out = route(alg, RoutingInput(graph, 1, 3))
        @test out.path == [1, 2, 3]        # Dijkstra 重建（此前恒为空）
        @test out.total_weight ≈ 42.0      # PINN 预测时延
        @test out.algorithm == "PINNRouting"

        out_self = route(alg, RoutingInput(graph, 2, 2))
        @test out_self.path == [2]
        @test out_self.total_weight == 0.0
    end

    @testset "A1: PINN 路由不连通标记 unreachable" begin
        graph = rimp_routing_graph(3, [(1, 2)], [1.0])   # 节点 3 孤立
        alg = PINNRoutingAlgorithm(nothing, (_p, _a, _s, _d) -> 7.0)
        out = route(alg, RoutingInput(graph, 1, 3))
        @test isempty(out.path)
        @test out.algorithm == "PINNRouting-unreachable"
    end
end

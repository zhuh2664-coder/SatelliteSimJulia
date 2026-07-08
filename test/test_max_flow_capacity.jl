# ===== 最大流网络容量（上界）测试 =====

using Test

using SatelliteSimJulia: max_flow_value, compute_network_capacity_maxflow,
    NetworkMaxFlowCapacityResult

@testset "最大流网络容量" begin

    @testset "钻石拓扑 max-flow" begin
        # 1→4 经 2、3 两条不相交路径，每边容量 10 → 最大流 20
        edges = Tuple{Int,Int}[(1, 2), (1, 3), (2, 4), (3, 4)]
        caps = fill(10.0, 4)
        @test max_flow_value(4, edges, caps, 1, 4) == 20.0
    end

    @testset "串联瓶颈" begin
        # 1-2 容量 5，2-3 容量 3 → 瓶颈 3
        @test max_flow_value(3, Tuple{Int,Int}[(1, 2), (2, 3)], [5.0, 3.0], 1, 3) == 3.0
    end

    @testset "边界情况" begin
        @test max_flow_value(4, Tuple{Int,Int}[(1, 2)], [10.0], 1, 1) == 0.0  # 源=汇
        @test max_flow_value(3, Tuple{Int,Int}[(1, 2)], [10.0], 1, 3) == 0.0  # 不连通
        # 平行边容量累加
        @test max_flow_value(2, Tuple{Int,Int}[(1, 2), (1, 2)], [5.0, 7.0], 1, 2) == 12.0
    end

    @testset "聚合上界" begin
        edges = Tuple{Int,Int}[(1, 2), (1, 3), (2, 4), (3, 4)]
        caps = fill(10.0, 4)
        r = compute_network_capacity_maxflow(4, edges, caps, Tuple{Int,Int}[(1, 4)])
        @test r isa NetworkMaxFlowCapacityResult
        @test r.per_pair_mbps == [20.0]
        @test r.total_capacity_gbps == 20.0 / 1000.0
        @test r.num_pairs == 1
        @test r.min_pair_mbps == 20.0
        @test r.mean_pair_mbps == 20.0
        # 空 pair
        empty_r = compute_network_capacity_maxflow(4, edges, caps, Tuple{Int,Int}[])
        @test empty_r.num_pairs == 0
        @test empty_r.total_capacity_gbps == 0.0
    end

    @testset "max-flow ≥ 贪心下界" begin
        # 上界不应小于贪心下界（同一拓扑、同一对）
        using SatelliteSimJulia: compute_network_capacity
        import Graphs
        g = Graphs.SimpleGraph(4)
        for (u, v) in [(1, 2), (1, 3), (2, 4), (3, 4)]
            Graphs.add_edge!(g, u, v)
        end
        pairs = Tuple{Int,Int}[(1, 4)]
        lower = compute_network_capacity(g, pairs; link_capacity_mbps = 100.0, step_mbps = 10.0)
        upper = compute_network_capacity_maxflow(g, pairs; link_capacity_mbps = 100.0)
        @test upper.total_capacity_gbps >= lower.total_capacity_gbps - 1e-9
    end
end

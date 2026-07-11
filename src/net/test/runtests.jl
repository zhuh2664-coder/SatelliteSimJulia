# src/net/test/runtests.jl — SatelliteSimNet 独立 smoke 测试
#
# 网络层：拓扑策略 + ISL 候选生成 + 路由（Dijkstra/ECMP/MinLoad/CGR）。
# 测试用已知小图验证距离矩阵，秒级完成。

using SatelliteSimNet
using Test

@testset "SatelliteSimNet" begin

    @testset "拓扑策略类型" begin
        @test GridPlusStrategy() isa AbstractTopologyStrategy
        @test SpiralStrategy() isa AbstractTopologyStrategy
        @test HoneycombStrategy() isa AbstractTopologyStrategy
        @test RingStrategy() isa AbstractTopologyStrategy
        @test MeshStrategy() isa AbstractTopologyStrategy
    end

    @testset "拓扑生成（GridPlus 小星座）" begin
        topo = generate_topology(GridPlusStrategy(), 6, 2)
        @test topo isa TopologyOutput
        @test !isempty(topo.static_links)
    end

    @testset "路由算法类型" begin
        @test DijkstraRouting() isa AbstractRoutingAlgorithm
        @test ECMPRouting() isa AbstractRoutingAlgorithm
        @test MinLoadRouting() isa AbstractRoutingAlgorithm
        @test CGRRouting() isa AbstractRoutingAlgorithm
    end

    @testset "邻接表 + 全对最短路径（已知小图）" begin
        # 4 节点链：1-2-3-4，边权全 1
        N = 4
        edges = [(1,2), (2,3), (3,4)]
        weights = [1.0, 1.0, 1.0]
        A = build_adjacency(N, edges, weights)
        @test size(A) == (N, N)
        D = all_pairs_shortest_paths(A)
        # 1→4 距离 = 3
        @test D[1,4] == 3.0
        @test D[1,2] == 1.0
        @test D[2,4] == 2.0
        # 对角线 0
        @test all(D[i,i] == 0.0 for i in 1:N)
    end

    @testset "路由输出构造" begin
        ro = RoutingOutput([1, 2, 3], 2.0, "Dijkstra")
        @test ro isa RoutingOutput
        @test ro.path == [1, 2, 3]
        @test ro.total_weight == 2.0
    end
end

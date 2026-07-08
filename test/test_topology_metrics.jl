# ===== 拓扑图论分析指标测试 =====
# 在已知小图上验证度分布/聚类系数/中心性/Fiedler/鲁棒性/churn 的正确性。

using Test
using Graphs
using Random: MersenneTwister
using SatelliteSimJulia
# 注意：degree_histogram / betweenness_centrality 等与 Graphs.jl 重名，
# 用 SatelliteSimJulia 限定命名空间避免歧义。
const M = SatelliteSimJulia

@testset "图论指标：路径图 P5 (1-2-3-4-5)" begin
    g = path_graph(5)

    # 度分布：2 个端点度 1，3 个中间节点度 2
    @test M.degree_histogram(g) == [2, 3]

    # 聚类系数：路径图无三角形 → 0
    @test M.clustering_coefficient(g) == 0.0

    # 介数中心性：中心节点 3 最大
    bc = M.betweenness_centrality(g)
    @test argmax(bc) == 3
    @test bc[1] ≈ 0.0 atol = 1e-9
    @test bc[3] ≈ 2 / 3 atol = 1e-3  # n=5: (n-1)(n-2)/2 = 6, raw=4 → 4/6

    # 接近中心性：中心节点 3 最大
    cc = M.closeness_centrality(g)
    @test argmax(cc) == 3

    # Fiedler 代数连通度：路径图 P5 = 2(1-cos(π/5)) ≈ 0.38197
    @test M.algebraic_connectivity(g) ≈ 2 * (1 - cos(π / 5)) atol = 1e-3
end

@testset "图论指标：完全图 K5" begin
    g = complete_graph(5)

    # 聚类系数：完全图 = 1.0
    @test M.clustering_coefficient(g) == 1.0

    # Fiedler：K_n 的代数连通度 = n，K5 = 5
    @test M.algebraic_connectivity(g) ≈ 5.0 atol = 1e-9

    # 介数中心性：完全图任意对都有直连边，无中介节点 → 全 0
    @test all(isapprox.(M.betweenness_centrality(g), 0.0; atol=1e-9))

    # Pagerank：完全图对称，所有节点 PR 相等 = 1/n = 0.2
    pr = M.pagerank(g)
    @test all(isapprox.(pr, 0.2; atol=1e-4))
    @test sum(pr) ≈ 1.0 atol = 1e-6
end

@testset "图论指标：不连通图" begin
    # 两个分离的三角形 {1,2,3} 和 {4,5,6}
    g = SimpleGraph(6)
    add_edge!(g, 1, 2); add_edge!(g, 2, 3); add_edge!(g, 1, 3)
    add_edge!(g, 4, 5); add_edge!(g, 5, 6); add_edge!(g, 4, 6)

    # 不连通 → Fiedler = 0
    @test M.algebraic_connectivity(g) ≈ 0.0 atol = 1e-9

    # 聚类系数：三角形 → 1.0
    @test M.clustering_coefficient(g) == 1.0
end

@testset "鲁棒性曲线" begin
    g = path_graph(10)

    # 蓄意攻击（按度从大到小删）：曲线单调不增，起点 1.0
    curve = M.robustness_curve(g; attack=:targeted, n_steps=5)
    @test length(curve) == 6  # 含初始点
    @test curve[1] == 1.0
    @test all(diff(curve) .<= 1e-9)  # 单调不增

    # 随机攻击：起点也是 1.0
    curve_r = M.robustness_curve(g; attack=:random, n_steps=5,
                                 rng=MersenneTwister(42))
    @test curve_r[1] == 1.0
    @test curve_r[end] < 1.0
end

@testset "时变 churn 度量" begin
    # 3 帧序列：帧2不变，帧3 删(1,2) 加(3,4)
    series = [
        [(1, 2), (2, 3)],
        [(1, 2), (2, 3)],
        [(2, 3), (3, 4)],
    ]

    # link_churn：帧1→2 = 0, 帧2→3 = 2（删1条+加1条）
    @test M.link_churn(series) == [0, 2]

    # 归一化 churn 率：avg_churn=1, avg_edges=2 → 0.5
    @test M.topology_churn_rate(series) ≈ 0.5 atol = 1e-9

    # 未归一化：avg churn = 1.0
    @test M.topology_churn_rate(series; normalize=false) ≈ 1.0 atol = 1e-9

    # 全静态序列 → 全 0
    static = [[(1, 2)], [(1, 2)], [(1, 2)]]
    @test all(M.link_churn(static) .== 0)
    @test M.topology_churn_rate(static) == 0.0

    # 单帧序列：churn 为空，率为 0
    @test isempty(M.link_churn([[(1, 2)]]))
    @test M.topology_churn_rate([[(1, 2)]]) == 0.0
end

println("✅ 所有图论分析指标测试通过")

# src/metrics/test/runtests.jl — SatelliteSimMetrics 独立 smoke 测试
#
# 指标层：覆盖/时延/网络/利用率/路由指标 + 图论分析（度/聚类/中心性/Fiedler）。
# 依赖 Foundation + Graphs。测试用已知小图验证，秒级完成。
# 注意：degree_histogram/clustering_coefficient 等与 Graphs.jl 重名，
# 用 SatelliteSimMetrics 限定命名空间避免歧义。

using SatelliteSimMetrics
using SatelliteSimFoundation
using Graphs
using Test

const M = SatelliteSimMetrics

@testset "SatelliteSimMetrics" begin

    @testset "图论指标：路径图 P5 (1-2-3-4-5)" begin
        g = path_graph(5)
        # 度分布：2 个端点度 1，3 个中间节点度 2
        @test M.degree_histogram(g) == [2, 3]
        # 聚类系数：路径图无三角形 → 0
        @test M.clustering_coefficient(g) == 0.0
    end

    @testset "图论指标：完全图 K5" begin
        g = complete_graph(5)
        # K5 每点度 4 → degree_histogram 索引 4 处为 5（5 个节点都度 4）
        @test M.degree_histogram(g) == [0, 0, 0, 5]
        # K5 聚类系数 = 1（每对邻居都相连）
        @test M.clustering_coefficient(g) == 1.0
    end

    @testset "图论指标：不连通图" begin
        g = SimpleGraph(4)
        add_edge!(g, 1, 2)
        # 代数连通性（Fiedler）应为 0（不连通）
        @test M.algebraic_connectivity(g) ≈ 0.0 atol=1e-9
    end

    @testset "结果类型构造" begin
        @test CoverageResult isa DataType
        @test LatencyResult isa DataType
        @test NetworkMetrics isa DataType
        @test UtilizationResult isa DataType
        @test RoutingMetrics isa DataType
    end

    @testset "指标注册表" begin
        @test !isempty(list_metrics())
        @test :coverage in list_metrics()
        # metric_type 返回指标实例（非 Type）
        @test metric_type(:coverage) !== nothing
    end
end

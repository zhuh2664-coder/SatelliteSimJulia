# ===== 指标计算测试 =====

using Test

using SatelliteSimCore: compute_coverage, compute_latency,
    compute_network_metrics, compute_link_utilization

@testset "指标计算" begin

    @testset "覆盖率 — 全部覆盖" begin
        gsl = trues(3, 2)  # 3 颗卫星，2 个用户
        result = compute_coverage(gsl, ["u1", "u2"])
        @test result.coverage_ratio ≈ 1.0
        @test length(result.covered_users) == 2
        @test result.total_users == 2
    end

    @testset "覆盖率 — 部分覆盖" begin
        gsl = [true false; false true; false false]  # 3 星 2 用户
        result = compute_coverage(gsl, ["u1", "u2"])
        @test result.coverage_ratio ≈ 1.0  # 每个用户至少被一颗覆盖
        @test length(result.covered_users) == 2
    end

    @testset "覆盖率 — 无覆盖" begin
        gsl = falses(3, 2)
        result = compute_coverage(gsl, ["u1", "u2"])
        @test result.coverage_ratio ≈ 0.0
        @test isempty(result.covered_users)
    end

    @testset "覆盖率 — 用户数不匹配" begin
        @test_throws ArgumentError compute_coverage(trues(3, 2), ["u1"])
    end

    @testset "延迟 — 正常" begin
        D = [0.0 1.0 2.0; 1.0 0.0 1.0; 2.0 1.0 0.0]
        result = compute_latency(D)
        @test result.avg_latency_ms ≈ 8/6  # (1+2+1+1+2+1)/6
        @test result.max_latency_ms ≈ 2.0
        @test result.min_latency_ms ≈ 1.0  # 排除对角线 0
        @test result.path_count == 6
    end

    @testset "延迟 — 有不可达" begin
        D = [0.0 1.0 Inf; 1.0 0.0 Inf; Inf Inf 0.0]
        result = compute_latency(D)
        @test result.avg_latency_ms ≈ 1.0
        @test result.path_count == 2  # 只有 1→2 和 2→1
    end

    @testset "延迟 — 全不可达" begin
        D = fill(Inf, 3, 3)
        for i in 1:3
            D[i, i] = 0.0
        end
        result = compute_latency(D)
        @test result.avg_latency_ms ≈ 0.0
        @test result.path_count == 0
    end

    @testset "网络指标 — 全连通" begin
        D = [0.0 1.0 2.0; 1.0 0.0 1.0; 2.0 1.0 0.0]
        result = compute_network_metrics(D)
        @test result.diameter ≈ 2.0
        @test result.avg_path_length ≈ 8/6  # (1+2+1+1+2+1)/6
        @test result.is_connected == true
        @test result.connectivity_ratio ≈ 1.0
    end

    @testset "网络指标 — 不连通" begin
        D = [0.0 1.0 Inf; 1.0 0.0 Inf; Inf Inf 0.0]
        result = compute_network_metrics(D)
        @test result.is_connected == false
        @test result.connectivity_ratio ≈ 2/6  # 2 个有限对 / 6 个总对
    end

    @testset "网络指标 — 单节点" begin
        D = [0.0;;]  # 1×1 矩阵
        result = compute_network_metrics(D)
        @test result.diameter ≈ 0.0
        @test result.is_connected == false  # 单节点无路径，不算连通
        @test result.connectivity_ratio ≈ 0.0
    end

    @testset "链路利用率 — 正常" begin
        used = [100.0, 500.0, 800.0]
        max_bw = [1000.0, 1000.0, 1000.0]
        result = compute_link_utilization(used, max_bw)
        @test result.avg_utilization ≈ 0.4666667 atol=1e-6
        @test result.max_utilization ≈ 0.8
        @test result.min_utilization ≈ 0.1
        @test result.bottleneck_links == [3]  # 链路 3 利用率为 0.8，满足 >=0.8
    end

    @testset "链路利用率 — 空" begin
        result = compute_link_utilization(Float64[], Float64[])
        @test result.avg_utilization ≈ 0.0
        @test isempty(result.bottleneck_links)
    end

    @testset "链路利用率 — 长度不匹配" begin
        @test_throws ArgumentError compute_link_utilization([1.0], [1.0, 2.0])
    end

end

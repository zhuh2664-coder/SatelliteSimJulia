# src/traffic/test/runtests.jl — SatelliteSimTraffic 独立 smoke 测试
#
# 流量层：需求模式 + AON 分配 + 时变需求 + 电池 SOC + 桥接 evaluate_traffic。
# 依赖 Foundation/Link/Net。测试最小场景验证类型与桥接函数存在，秒级完成。

using SatelliteSimTraffic
using SatelliteSimFoundation
using Test

@testset "SatelliteSimTraffic" begin

    @testset "需求类型构造" begin
        @test TrafficDemand isa DataType
        @test TrafficEvaluation isa DataType
        @test TrafficAssignment isa DataType
        @test LinkLoadSample isa DataType
        # 需求模式
        @test UniformSolar isa DataType
        @test DiurnalPattern isa DataType
        @test PoissonArrivalPattern isa DataType
        @test PopulationWeightedPattern isa DataType
    end

    @testset "速率profile" begin
        @test ConstantRate isa DataType
        @test FunctionalRate isa DataType
        # ConstantRate 应可构造；rate_at 接受 Int 秒
        cr = ConstantRate(100.0)
        @test rate_at(cr, 0) == 100.0
    end

    @testset "电池/功率模型" begin
        @test PowerState isa DataType
        @test PowerStateSeries isa DataType
        @test EclipseSolar isa DataType
        @test CommunicationPowerModel isa DataType
    end

    @testset "桥接函数存在性" begin
        @test evaluate_traffic_from_bare_arrays isa Function
        @test evaluate_traffic isa Function
        @test generate_demands isa Function
        @test evolve_power_states isa Function
        @test initial_power_state isa Function
    end

    @testset "桥接接受矩阵视图序列" begin
        positions_parent = zeros(Float32, 2, 1, 3)
        positions_parent[1, 1, 1] = 7000
        positions_parent[2, 1, 1] = 7100
        positions = @view positions_parent[:, :, :]

        avail_parent = reshape(Bool[true, false, false, true], 2, 2, 1)
        dist_parent = reshape(Float32[500, 1000, 1000, 500], 2, 2, 1)
        elev_parent = reshape(Float32[80, -10, -10, 80], 2, 2, 1)
        avail_by_time = [@view avail_parent[:, :, 1]]
        dist_by_time = [@view dist_parent[:, :, 1]]
        elev_by_time = [@view elev_parent[:, :, 1]]

        isl_results = [[(
            available=true,
            distance_km=100.0,
            latency_ms=100.0 / 299792.458 * 1000,
            line_of_sight=true,
        )]]
        grid = SimulationTimeGrid(default_starlink_simulation_epoch(), 0, 1)
        demand = TrafficDemand(
            id=1,
            source_ground_id=1,
            destination_ground_id=2,
            start_elapsed_s=0,
            end_elapsed_s=1,
            rate_mbps=10.0,
        )

        evaluation = evaluate_traffic_from_bare_arrays(
            positions,
            [(1, 2)],
            isl_results,
            avail_by_time,
            dist_by_time,
            elev_by_time,
            [1, 2],
            grid,
            [demand],
        )
        @test first(first(evaluation.assignments_by_time)).route.reachable
    end

    @testset "需求生成" begin
        # generate_demands(pattern, ground_ids, t0_s, duration_s; rng)
        ground_ids = collect(1:3)
        demands = generate_demands(DiurnalPattern(), ground_ids, 0, 600)
        @test demands isa Vector{TrafficDemand}
        @test length(demands) >= 1
    end
end

# src/traffic/test/runtests.jl — SatelliteSimTraffic 独立 smoke 测试
#
# 流量层：需求模式 + AON 分配 + 时变需求 + 电池 SOC + 桥接 evaluate_traffic。
# 依赖 Foundation/Link/Net。测试最小场景验证类型与桥接函数存在，秒级完成。

using SatelliteSimTraffic
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

    @testset "需求生成" begin
        # generate_demands(pattern, ground_ids, t0_s, duration_s; rng)
        ground_ids = collect(1:3)
        demands = generate_demands(DiurnalPattern(), ground_ids, 0, 600)
        @test demands isa Vector{TrafficDemand}
        @test length(demands) >= 1
    end
end

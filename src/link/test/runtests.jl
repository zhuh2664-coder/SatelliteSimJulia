# src/link/test/runtests.jl — SatelliteSimLink 独立 smoke 测试
#
# 链路层：物理约束 + ISL/GSL 批评估 + 几何变换 + 天气/雨衰/DVB-S2 模型。
# 依赖 Foundation + Orbit。测试用 2 卫星最小场景验证可见性与几何，秒级完成。

using SatelliteSimLink
using SatelliteSimFoundation
using SatelliteSimOrbit
using Test

@testset "SatelliteSimLink" begin

    @testset "物理约束默认值" begin
        @test LEO_DEFAULTS isa PhysicalConstraints
        @test LEO_DEFAULTS.isl_max_capacity_mbps > 0
    end

    @testset "几何变换往返" begin
        # 北京坐标 → ECEF → 反变换应近似闭合
        ecef = geodetic_to_ecef_km(39.9, 116.4, 0.0)
        @test all(isfinite, ecef)
        # ecef 是 Tuple，手动算模长（约地球半径，北京纬度处约 6369km）
        r_km = sqrt(ecef[1]^2 + ecef[2]^2 + ecef[3]^2)
        @test 6360.0 < r_km < 6380.0
        lla = ecef_to_geodetic_lla(ecef...)
        @test lla[1] ≈ 39.9 atol=1e-6
        @test lla[2] ≈ 116.4 atol=1e-6
    end

    @testset "ISL 批评估" begin
        # evaluate_isl_batch 要 Matrix{Float64}(N×3 单时间步)，不是 3D
        elems = generate_walker_delta(; T=6, P=2, F=0, alt_km=550.0, inc_deg=53.0)
        pos = propagate_to_ecef(elems, [0.0]; propagator=TwoBodyPropagator())
        pos_2d = pos[:, 1, :]   # N×3 单时间步
        links = [(1, 2), (1, 3)]
        results = evaluate_isl_batch(pos_2d, links; constraints=LEO_DEFAULTS)
        @test length(results) == 2
        @test all(r -> hasproperty(r, :available), results)
        @test all(r -> hasproperty(r, :latency_ms), results)
    end

    @testset "天气/雨衰模型存在性" begin
        # 新增的天气模型应已导出
        @test RainParameters isa DataType
        @test WeatherState isa DataType
        @test WeatherTimeSeries isa DataType
        @test WeatherAwareCapacityModel isa DataType
        @test DVB_S2_MODCODS isa AbstractVector
        @test length(DVB_S2_MODCODS) > 10   # DVB-S2 有 24 个 MODCOD
    end

    @testset "链路预算函数" begin
        @test link_budget isa Function
        @test rain_attenuation_db isa Function
        @test select_modcod isa Function
        @test effective_capacity_mbps isa Function
    end
end

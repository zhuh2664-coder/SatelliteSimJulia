# src/core/test/runtests.jl — SatelliteSimCore 独立 smoke 测试
#
# Core 是 re-export 枢纽层：聚合 Foundation/Orbit/Link/Metrics 的全部公开符号。
# 测试策略：验证关键符号从 Core 可见（isdefined），不重复测底层逻辑（那是各子包的职责）。

using SatelliteSimCore
using Test

@testset "SatelliteSimCore re-export" begin

    @testset "Foundation 符号可见" begin
        @test isdefined(SatelliteSimCore, :SimulationTimeGrid)
        @test isdefined(SatelliteSimCore, :SimulationEpoch)
        @test isdefined(SatelliteSimCore, :GeodeticPosition)
        @test isdefined(SatelliteSimCore, :CartesianState)
        @test isdefined(SatelliteSimCore, :GroundStation)
        @test isdefined(SatelliteSimCore, :WGS84_EQUATORIAL_RADIUS_KM)
        @test isdefined(SatelliteSimCore, :default_starlink_simulation_epoch)
    end

    @testset "Orbit 符号可见" begin
        @test isdefined(SatelliteSimCore, :generate_walker_delta)
        @test isdefined(SatelliteSimCore, :propagate_to_ecef)
        @test isdefined(SatelliteSimCore, :TwoBodyPropagator)
        @test isdefined(SatelliteSimCore, :J2Propagator)
        @test isdefined(SatelliteSimCore, :positions_at_last)
        @test isdefined(SatelliteSimCore, :n_satellites)
    end

    @testset "Link 符号可见" begin
        @test isdefined(SatelliteSimCore, :evaluate_isl_batch)
        @test isdefined(SatelliteSimCore, :evaluate_gsl_batch)
        @test isdefined(SatelliteSimCore, :PhysicalConstraints)
        @test isdefined(SatelliteSimCore, :LEO_DEFAULTS)
        @test isdefined(SatelliteSimCore, :link_budget)
        @test isdefined(SatelliteSimCore, :DVB_S2_MODCODS)
    end

    @testset "Metrics 符号可见" begin
        @test isdefined(SatelliteSimCore, :CoverageResult)
        @test isdefined(SatelliteSimCore, :LatencyResult)
        @test isdefined(SatelliteSimCore, :NetworkMetrics)
        @test isdefined(SatelliteSimCore, :compute_coverage)
        @test isdefined(SatelliteSimCore, :compute_latency)
        @test isdefined(SatelliteSimCore, :degree_histogram)
    end

    @testset "端到端最小调用链" begin
        # 从 Core 直接调通：生成星座 → 传播 → 位置
        elems = SatelliteSimCore.generate_walker_delta(; T=6, P=2, F=0, alt_km=550.0)
        pos = SatelliteSimCore.propagate_to_ecef(elems, [0.0]; propagator=TwoBodyPropagator())
        @test size(pos) == (6, 1, 3)
        @test SatelliteSimCore.n_satellites(pos) == 6
    end
end

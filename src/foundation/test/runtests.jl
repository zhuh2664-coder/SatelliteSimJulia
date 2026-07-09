# src/foundation/test/runtests.jl — SatelliteSimFoundation 独立 smoke 测试
#
# 最底层包：时间系统、坐标系、几何常量、基础实体。
# 不依赖任何其它 SatelliteSim 包，测试应秒级完成。

using SatelliteSimFoundation
using Test

@testset "SatelliteSimFoundation" begin

    @testset "时间系统" begin
        ep = default_starlink_simulation_epoch()
        @test ep isa SimulationEpoch
        grid = SimulationTimeGrid(ep, 600, 60)
        @test grid.duration_s == 600
        @test grid.step_s == 60
        # time_count 应返回时间步数
        @test time_count(grid) >= 1
    end

    @testset "坐标系与几何常量" begin
        @test WGS84_EQUATORIAL_RADIUS_KM > 6370.0
        @test SPEED_OF_LIGHT_KM_S > 290000.0
        @test MU_KM3_S2 > 390000.0
        gp = GeodeticPosition(39.9, 116.4, 0.0)
        @test gp isa GeodeticPosition
        cs = CartesianState(ECEF, (7000.0, 0.0, 0.0), (0.0, 7.5, 0.0))
        @test cs isa CartesianState
        @test cs.position_km == (7000.0, 0.0, 0.0)
    end

    @testset "实体类型" begin
        @test Satellite isa DataType
        @test GroundStation isa DataType
        @test UserTerminal isa DataType
        @test SatelliteConfig isa DataType
        # 默认配置常量存在
        @test DEFAULT_SAT_CONFIG isa SatelliteConfig
    end

    @testset "链路类型契约" begin
        @test InterSatelliteLink isa DataType
        @test GroundSatelliteLink isa DataType
        @test LinkAvailable isa Type
        @test LinkUnavailable isa Type
    end
end

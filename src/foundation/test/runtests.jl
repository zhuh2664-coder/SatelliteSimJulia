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
        @test GroundEndpoint isa DataType
        @test SatelliteConfig isa DataType
        # 默认配置常量存在
        @test DEFAULT_SAT_CONFIG isa SatelliteConfig
    end

    @testset "GroundEndpoint 统一端点" begin
        ep = GroundEndpoint("beijing", 39.9042, 116.4074, 0.0)
        @test ep.id == "beijing"
        @test ep.position.latitude_deg ≈ 39.9042
        @test ep.position.longitude_deg ≈ 116.4074
        @test ep.position.altitude_km == 0.0
        @test ep.uplink_demand_mbps == 0.0
        @test ep.downlink_demand_mbps == 0.0
        @test ground_endpoint_tuple(ep) == (39.9042, 116.4074, 0.0)

        station = GroundStation(id=1, name="durham", position=GeodeticPosition(35.9940, -78.8986, 0.0))
        station_ep = GroundEndpoint(station)
        @test station_ep.id == "1"
        @test station_ep.tags["name"] == "durham"
        @test ground_endpoint_tuple(station_ep) == (35.9940, -78.8986, 0.0)

        terminal = UserTerminal(id=2, name="mobile", position=GeodeticPosition(1.0, 2.0, 3.0))
        terminal_ep = GroundEndpoint(terminal)
        @test terminal_ep.id == "2"
        @test terminal_ep.tags["name"] == "mobile"
        @test ground_endpoint_tuple(terminal_ep) == (1.0, 2.0, 3.0)

        # tags 排序保证 repr 稳定（用于缓存 config_hash）
        ep_a = GroundEndpoint("a", 0.0, 0.0, 0.0; tags=Dict("z" => "1", "a" => "2"))
        ep_b = GroundEndpoint("a", 0.0, 0.0, 0.0; tags=Dict("a" => "2", "z" => "1"))
        @test repr(ep_a) == repr(ep_b)

        # 非法坐标应报错
        @test_throws ArgumentError GroundEndpoint("bad", 91.0, 0.0, 0.0)
        @test_throws ArgumentError GroundEndpoint("bad", 0.0, 181.0, 0.0)
    end

    @testset "链路类型契约" begin
        @test InterSatelliteLink isa DataType
        @test GroundSatelliteLink isa DataType
        @test LinkAvailable isa Type
        @test LinkUnavailable isa Type
    end
end

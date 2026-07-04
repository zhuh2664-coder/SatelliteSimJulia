using Test
using SatelliteSimCore

@testset "Layer 0 Baseline - 类型系统重构验证" begin

    # ════════════════════════════════════════════════════════════
    # 1. 临时兼容层验证
    # ════════════════════════════════════════════════════════════

    @testset "Legacy Compatibility Layer" begin
        # SatelliteId 应该是 Int 的别名
        @test SatelliteId === Int

        # Constellation 应该是 Vector{Satellite} 的别名
        @test Constellation === Vector{Satellite}

        # SatelliteStatus 枚举应该可用
        @test ACTIVE isa SatelliteStatus
        @test INACTIVE isa SatelliteStatus
        @test FAILED isa SatelliteStatus
        @test DECOMMISSIONED isa SatelliteStatus

        # StateConfig 应该可以构造
        state = StateConfig(x=7000.0, vy=7.5)
        @test state.x == 7000.0
        @test state.vy == 7.5
        @test state.status == ACTIVE
    end

    # ════════════════════════════════════════════════════════════
    # 2. 新实体系统验证
    # ════════════════════════════════════════════════════════════

    @testset "New Entity System" begin
        # 测试 Satellite 构造
        orbit = DesignOrbitElementSet(altitude_km=550, inclination_deg=53)
        config = SatelliteConfig()
        sat = Satellite(id=1, orbit=orbit, config=config)

        @test sat.id == 1
        @test sat.orbit isa AbstractOrbitElementSet
        @test sat.config isa SatelliteConfig

        # 测试 GroundStation 构造
        pos = GeodeticPosition(40.0, -75.0, 0.0)  # 使用位置参数
        gs = GroundStation(id=1, position=pos)

        @test gs.id == 1
        @test gs.position.latitude_deg == 40.0

        # 测试 UserTerminal 构造
        user = UserTerminal(id=1, position=pos)

        @test user.id == 1
        @test user.position.latitude_deg == 40.0
    end

    # ════════════════════════════════════════════════════════════
    # 3. 轨道根数层次验证
    # ════════════════════════════════════════════════════════════

    @testset "Orbit Element Set Hierarchy" begin
        # DesignOrbitElementSet
        design = DesignOrbitElementSet(
            altitude_km=550,
            inclination_deg=53,
            raan_deg=10,
            mean_anomaly_deg=20
        )
        @test design.altitude_km == 550
        @test design.inclination_deg == 53
        @test design.raan_deg == 10

        # EarthFixedOrbitElementSet
        fixed = EarthFixedOrbitElementSet(longitude_deg=-75)
        @test fixed.longitude_deg == -75
        @test fixed.altitude_km == 0

        # TLEOrbitElementSet
        tle = TLEOrbitElementSet(
            "STARLINK-123",
            "1 12345U 20001A   20123.4567890 .0000000  00000-0  00000+0 0  0001",
            "2 12345  53.0000  10.0000 0000000  20.0000 340.0000 15.00000000000001"
        )
        @test tle.satellite_name == "STARLINK-123"
    end

    # ════════════════════════════════════════════════════════════
    # 4. 物理常量验证
    # ════════════════════════════════════════════════════════════

    @testset "Physical Constants" begin
        @test SPEED_OF_LIGHT_KM_S ≈ 299_792.458
        @test WGS84_EQUATORIAL_RADIUS_KM ≈ 6378.137
        @test MU_KM3_S2 ≈ 398600.4415
        @test OMEGA_EARTH ≈ 7.2921150e-5
    end

    # ════════════════════════════════════════════════════════════
    # 5. 组织关系验证
    # ════════════════════════════════════════════════════════════

    @testset "Organization Relations" begin
        # 创建几个卫星
        sats = [
            Satellite(id=1, orbit=DesignOrbitElementSet(altitude_km=550, inclination_deg=53, raan_deg=0), config=SatelliteConfig()),
            Satellite(id=2, orbit=DesignOrbitElementSet(altitude_km=550, inclination_deg=53, raan_deg=0), config=SatelliteConfig()),
            Satellite(id=3, orbit=DesignOrbitElementSet(altitude_km=550, inclination_deg=53, raan_deg=10), config=SatelliteConfig()),
        ]

        # 按 RAAN 分组
        planes = group_by_raan(sats)
        @test length(planes) == 2  # 两个不同的 RAAN

        # 创建 Shell
        shell = Shell(altitude_km=550, inclination_deg=53, planes=planes)
        @test shell.altitude_km == 550
        @test length(shell.planes) == 2

        # 获取所有卫星
        all_sats = satellites(shell)
        @test length(all_sats) == 3
    end
end

println("\n✅ Layer 0 Baseline 测试全部通过！")
println("临时兼容层已就位，可以开始 Layer 1-2 重构。")
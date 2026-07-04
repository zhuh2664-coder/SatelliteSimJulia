using Test
using SatelliteSimCore
using Dates: DateTime

@testset "Ephemeris System - Layer 1" begin

    # ════════════════════════════════════════════════════════════
    # 1. EphemerisSample 测试
    # ════════════════════════════════════════════════════════════

    @testset "EphemerisSample" begin
        # 创建笛卡尔状态
        cartesian = CartesianState(ECEF, (7000.0, 0.0, 0.0), (0.0, 7.5, 0.0))

        # 创建样本
        sample = EphemerisSample(
            satellite_id=1,
            time_index=1,
            elapsed_s=0,
            cartesian=cartesian
        )

        @test sample.satellite_id == 1
        @test sample.time_index == 1
        @test sample.elapsed_s == 0
        @test sample.cartesian !== nothing
        @test sample.geodetic === nothing

        # 测试验证：必须提供至少一种位置
        @test_throws ArgumentError EphemerisSample(
            satellite_id=1,
            time_index=1,
            elapsed_s=0
        )
    end

    # ════════════════════════════════════════════════════════════
    # 2. SatelliteEphemeris 测试
    # ════════════════════════════════════════════════════════════

    @testset "SatelliteEphemeris" begin
        # 创建时间序列样本
        samples = [
            EphemerisSample(
                satellite_id=1,
                time_index=i,
                elapsed_s=(i-1)*60,
                cartesian=CartesianState(ECEF, (7000.0 + i*10, 0.0, 0.0), nothing)
            )
            for i in 1:10
        ]

        # 创建卫星星历
        sat_ephem = SatelliteEphemeris(1, samples)

        @test sat_ephem.satellite_id == 1
        @test length(sat_ephem) == 10
        @test sat_ephem[5].time_index == 5  # 索引访问

        # 测试验证：样本必须属于同一卫星
        bad_samples = [
            EphemerisSample(
                satellite_id=i,  # 不同的 satellite_id
                time_index=1,
                elapsed_s=0,
                cartesian=CartesianState(ECEF, (7000.0, 0.0, 0.0), nothing)
            )
            for i in 1:3
        ]
        @test_throws ArgumentError SatelliteEphemeris(1, bad_samples)
    end

    # ════════════════════════════════════════════════════════════
    # 3. ConstellationEphemeris 测试
    # ════════════════════════════════════════════════════════════

    @testset "ConstellationEphemeris" begin
        # 创建时间网格
        epoch = SimulationEpoch(DateTime(2020, 1, 1, 0, 0, 0))
        time_grid = SimulationTimeGrid(epoch, 600, 60)  # epoch, total_duration_s, step_s
        # 600秒 / 60秒 = 11 个时间片 (包括 0 和 600)

        # 创建两颗卫星的星历（11个时间片）
        sats_ephem = [
            SatelliteEphemeris(i, [
                EphemerisSample(
                    satellite_id=i,
                    time_index=j,
                    elapsed_s=(j-1)*60,  # 0, 60, 120, ..., 600
                    cartesian=CartesianState(ECEF, (7000.0 + i*100 + j*10, 0.0, 0.0), nothing)
                )
                for j in 1:11  # 11 个时间片
            ])
            for i in 1:2
        ]

        # 创建星座星历
        const_ephem = ConstellationEphemeris("test_constellation", time_grid, sats_ephem)

        @test const_ephem.constellation_name == "test_constellation"
        @test length(const_ephem) == 2  # 两颗卫星
        @test const_ephem[1].satellite_id == 1  # 按索引访问
        @test const_ephem[2].satellite_id == 2

        # 按卫星对象访问（需要 Satellite 类型）
        orbit = DesignOrbitElementSet(altitude_km=550, inclination_deg=53)
        config = SatelliteConfig()
        sat1 = Satellite(id=1, orbit=orbit, config=config)
        @test const_ephem[sat1].satellite_id == 1

        # 展平测试
        all_samples = ephemeris_samples(const_ephem)
        @test length(all_samples) == 22  # 2 satellites × 11 time steps
    end

    # ════════════════════════════════════════════════════════════
    # 4. attach_geodetic 测试
    # ════════════════════════════════════════════════════════════

    @testset "attach_geodetic" begin
        # 创建时间网格
        epoch = SimulationEpoch(DateTime(2020, 1, 1, 0, 0, 0))
        time_grid = SimulationTimeGrid(epoch, 600, 60)

        # 创建 TEME 样本
        teme_sample = EphemerisSample(
            satellite_id=1,
            time_index=1,
            elapsed_s=0,
            cartesian=CartesianState(TEME, (7000.0, 0.0, 0.0), (0.0, 7.5, 0.0))
        )

        # 添加经纬高
        transform = SimpleTemeToGeodeticTransform()
        geo_sample = attach_geodetic(teme_sample, transform, time_grid)

        @test geo_sample.geodetic !== nothing
        @test geo_sample.cartesian !== nothing  # 原有笛卡尔坐标保留
    end
end

println("\n✅ Ephemeris System 测试全部通过！")
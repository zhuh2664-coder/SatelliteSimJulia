using Test
using SatelliteSimCore
using Dates: DateTime

@testset "完整集成测试 - Layer 0-2" begin

    # ════════════════════════════════════════════════════════════
    # 1. Walker-Delta 星座生成测试
    # ════════════════════════════════════════════════════════════

    @testset "Walker-Delta 星座生成" begin
        # 生成小型测试星座
        sats = generate_walker_constellation(T=24, P=6, F=1, alt_km=550.0, inc_deg=53.0)

        @test length(sats) == 24
        # 测试 id 连续性
        for (i, sat) in enumerate(sats)
            @test sat.id == i
        end
        # 测试轨道类型
        for sat in sats
            @test sat.orbit isa AbstractOrbitElementSet
        end
        # 测试轨道高度
        for sat in sats
            @test sat.orbit.altitude_km ≈ 550.0
        end
        # 测试轨道倾角
        for sat in sats
            @test sat.orbit.inclination_deg ≈ 53.0
        end

        # 测试极轨星座（RAAN 180°展开）
        polar_sats = generate_walker_constellation(T=12, P=3, F=1, alt_km=550.0, inc_deg=90.0)
        @test length(polar_sats) == 12
        @test polar_sats[1].orbit.raan_deg ≈ 0.0
        @test polar_sats[4].orbit.raan_deg ≈ 60.0  # 180° / 3
    end

    # ════════════════════════════════════════════════════════════
    # 2. 轨道传播测试
    # ════════════════════════════════════════════════════════════

    @testset "轨道传播" begin
        # 生成星座
        sats = generate_walker_constellation(T=4, P=2, F=0, alt_km=550.0, inc_deg=53.0)

        # 创建时间网格
        epoch = SimulationEpoch(DateTime(2020, 1, 1, 0, 0, 0))
        time_grid = SimulationTimeGrid(epoch, 600, 60)  # 10分钟，60秒步长

        # 使用 SGP4 传播器
        propagator = Sgp4PropagatorAdapter()

        # 传播整个星座
        ephem = propagate_constellation(propagator, sats, time_grid, "test_constellation")

        @test ephem.constellation_name == "test_constellation"
        @test length(ephem) == 4  # 4颗卫星
        @test time_count(time_grid) == 11  # 0, 60, ..., 600 (11个时间片)

        # 检查每颗卫星的星历
        for i in 1:4
            sat_ephem = ephem[i]
            @test sat_ephem.satellite_id == i
            @test length(sat_ephem) == 11
        end
    end

    # ════════════════════════════════════════════════════════════
    # 3. 链路评估测试
    # ════════════════════════════════════════════════════════════

    @testset "链路评估" begin
        # 创建两个位置（ECEF）
        pos_a = (7000.0, 0.0, 0.0)  # 卫星A
        pos_b = (7000.0, 1000.0, 0.0)  # 卫星B

        # 评估 ISL
        available, distance, los, delay, details = evaluate_isl(pos_a, pos_b)

        @test available == true
        @test distance ≈ 1000.0
        @test los == true
        @test delay > 0

        # 测试超距离情况
        pos_c = (7000.0, 10000.0, 0.0)  # 超过最大距离
        available2, distance2, los2, delay2, details2 = evaluate_isl(pos_a, pos_c)

        @test available2 == false  # 距离过远
    end

    # ════════════════════════════════════════════════════════════
    # 4. 完整工作流测试
    # ════════════════════════════════════════════════════════════

    @testset "完整工作流" begin
        # 步骤1：生成星座
        sats = generate_walker_constellation(T=8, P=2, F=1, alt_km=550.0, inc_deg=53.0)
        @test length(sats) == 8

        # 步骤2：创建时间网格
        epoch = SimulationEpoch(DateTime(2020, 1, 1, 0, 0, 0))
        time_grid = SimulationTimeGrid(epoch, 300, 60)  # 5分钟

        # 步骤3：传播轨道
        propagator = Sgp4PropagatorAdapter()
        ephem = propagate_constellation(propagator, sats, time_grid, "test")

        @test length(ephem) == 8
        @test time_count(time_grid) == 6  # 0, 60, 120, 180, 240, 300

        # 步骤4：获取某个时间片的位置
        t_idx = 3  # 第3个时间片（elapsed_s = 120s）
        sat1_sample = ephem[1][t_idx]
        sat2_sample = ephem[2][t_idx]

        @test sat1_sample.time_index == t_idx
        @test sat1_sample.elapsed_s == 120
        @test sat1_sample.cartesian !== nothing

        # 步骤5：评估 ISL（如果有笛卡尔坐标）
        if sat1_sample.cartesian !== nothing && sat2_sample.cartesian !== nothing
            pos1 = sat1_sample.cartesian.position_km
            pos2 = sat2_sample.cartesian.position_km

            available, distance, los, delay, details = evaluate_isl(pos1, pos2)

            # 记录结果（不强制要求可用，因为卫星可能相距较远）
            println("  ISL评估: sat1-sat2, 可用=$available, 距离=$distance km, LOS=$los")
        end
    end

    # ════════════════════════════════════════════════════════════
    # 5. 类型系统测试
    # ════════════════════════════════════════════════════════════

    @testset "类型系统" begin
        # 测试新类型别名
        @test SatelliteId === Int
        @test Constellation === Vector{Satellite}

        # 测试枚举
        @test ACTIVE isa SatelliteStatus
        @test INACTIVE isa SatelliteStatus

        # 测试 StateConfig
        state = StateConfig(x=7000.0, vy=7.5)
        @test state.x == 7000.0
        @test state.vy == 7.5
        @test state.status == ACTIVE
    end

    # ════════════════════════════════════════════════════════════
    # 6. 物理常量测试
    # ════════════════════════════════════════════════════════════

    @testset "物理常量" begin
        @test SPEED_OF_LIGHT_KM_S ≈ 299_792.458
        @test WGS84_EQUATORIAL_RADIUS_KM ≈ 6378.137
        @test MU_KM3_S2 ≈ 398600.4415
        @test OMEGA_EARTH ≈ 7.2921150e-5
    end
end

println("\n" * "="^60)
println("✅ 完整集成测试通过！")
println("="^60)
println("\n功能验证：")
println("  ✅ Walker-Delta 星座生成")
println("  ✅ 轨道传播（SGP4）")
println("  ✅ 星历数据管理")
println("  ✅ ISL 链路评估")
println("  ✅ 类型系统统一")
println("  ✅ 物理常量正确")
println("\n项目状态：可运行 ✅")
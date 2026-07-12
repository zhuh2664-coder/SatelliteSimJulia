# src/link/test/runtests.jl — SatelliteSimLink 独立 smoke 测试
#
# 链路层：物理约束 + ISL/GSL 批评估 + 几何变换 + 天气/雨衰/DVB-S2 模型。
# 依赖 Foundation + Orbit。测试用 2 卫星最小场景验证可见性与几何，秒级完成。

using SatelliteSimLink
using SatelliteSimBackends
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

        # 编排层按时间片取位置时使用 SubArray；链接口必须接受该零拷贝视图。
        results_view = evaluate_isl_batch(@view(pos[:, 1, :]), links; constraints=LEO_DEFAULTS)
        @test length(results_view) == 2

        # GSL 同样必须接受编排层传入的零拷贝时间片视图。
        gsl = evaluate_gsl_batch(@view(pos[:, 1, :]), [(0.0, 0.0, 0.0)]; constraints=LEO_DEFAULTS)
        @test size(gsl[1]) == (6, 1)

        series = evaluate_gsl_series(
            CPUComputeBackend(),
            @view(pos[:, :, :]),
            [(0.0, 0.0, 0.0)];
            gsl_min_elevation_deg=LEO_DEFAULTS.gsl_min_elevation_deg,
            gsl_max_range_km=LEO_DEFAULTS.gsl_max_range_km,
        )
        @test series.available[:, :, 1] == gsl[1]
        @test series.distance_km[:, :, 1] ≈ gsl[2]
        @test compute_backend_fingerprint(CPUComputeBackend()).implementation_module ==
              "SatelliteSimLink"
        cpu_source_files = compute_backend_source_files(CPUComputeBackend())
        @test all(isfile, cpu_source_files)
        @test any(endswith("geometry.jl"), cpu_source_files)
        @test any(endswith("constraints.jl"), cpu_source_files)
        @test_throws ArgumentError evaluate_gsl_series(
            CPUComputeBackend(),
            pos,
            [(0.0, 0.0, 0.0)];
            gsl_min_elevation_deg=25.0,
            gsl_max_range_km=0.0,
        )
    end

    @testset "ISL 时间序列契约（CPU 后端）" begin
        # 合成 (N, T, 3) 位置/速度，验证 evaluate_isl_series 逐时间片等于 evaluate_isl_batch。
        n_sat, n_times = 6, 4
        positions = Array{Float64}(undef, n_sat, n_times, 3)
        velocities = Array{Float64}(undef, n_sat, n_times, 3)
        for s in 1:n_sat, t in 1:n_times
            θ = 0.12 * (s - 1) + 0.02 * (t - 1)
            r = 6871.0 + 8.0 * s
            positions[s, t, :] .= (r * cos(θ), r * sin(θ), 40.0 * (s - 3))
            velocities[s, t, :] .= (-7.6 * sin(θ), 7.6 * cos(θ), 0.05 * (s - 3))
        end
        links = [(1, 2), (2, 3), (1, 4)]

        series = evaluate_isl_series(
            CPUComputeBackend(), positions, links; velocities=velocities,
        )
        @test series isa ISLSeriesResult
        @test size(series.available) == (length(links), n_times)
        @test series.metadata["backend"] == "cpu"

        # 与逐时间片 evaluate_isl_batch 完全对齐（编排层按时间片取 SubArray）。
        for t in 1:n_times
            batch = evaluate_isl_batch(
                @view(positions[:, t, :]), links;
                constraints=LEO_DEFAULTS, vel_matrix=@view(velocities[:, t, :]),
            )
            @test series.available[:, t] == [b.available for b in batch]
            @test series.distance_km[:, t] ≈ [b.distance_km for b in batch]
            @test series.delay_ms[:, t] ≈ [b.latency_ms for b in batch]
            @test series.line_of_sight[:, t] == [b.line_of_sight for b in batch]
            @test series.elevation_deg[:, t] ≈ [b.elevation_deg for b in batch]
            @test series.cos_psi[:, t] ≈ [b.cos_psi for b in batch]
            @test series.duration_s[:, t] ≈ [b.duration_s for b in batch]
        end

        # 位置-only 路径：无速度时仰角/方位保持默认值。
        series0 = evaluate_isl_series(CPUComputeBackend(), positions, links)
        @test all(series0.elevation_deg .== 90.0)
        @test all(series0.cos_psi .== 1.0)
        @test all(series0.duration_s .== 0.0)

        # 空 pairs 与非法索引的边界行为。
        empty_series = evaluate_isl_series(CPUComputeBackend(), positions, Tuple{Int,Int}[])
        @test size(empty_series.available) == (0, n_times)
        @test_throws ArgumentError evaluate_isl_series(
            CPUComputeBackend(), positions, [(1, 99)]; velocities=velocities,
        )
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

# ===== ITU-R P.618 雨衰模型测试 =====
# 覆盖两处修复：
#   1) effective_path_length_km 的垂直调整因子 v_0.01（此前低仰角分支是伪分支）
#   2) rain_attenuation_db 的 availability_pct → p% 时间百分比外推（此前参数被忽略）

using Test

using SatelliteSimLink: RainParameters, rain_specific_attenuation,
    slant_path_length_km, effective_path_length_km, rain_attenuation_db,
    rain_height_km

@testset "rain attenuation (ITU-R P.618)" begin
    # Ka 波段 GSL、中纬度、重雨（R_0.01 = 42 mm/h）
    rp = RainParameters(;
        frequency_ghz = 20.0,
        elevation_deg = 30.0,
        rain_rate_mm_h = 42.0,
        latitude_deg = 40.0,
        altitude_km = 0.0,
    )

    @testset "基础量非负且有限" begin
        @test rain_specific_attenuation(rp) > 0
        @test slant_path_length_km(rp) > 0
        @test isfinite(effective_path_length_km(rp))
        @test effective_path_length_km(rp) > 0
    end

    @testset "有效路径长度 <= 斜路径长度（缩减因子作用）" begin
        # r_0.01, v_0.01 ∈ (0,1]，故 L_E 不应超过 L_S
        @test effective_path_length_km(rp) <= slant_path_length_km(rp) + 1e-9
    end

    @testset "availability_pct 真正生效且单调" begin
        A_001 = rain_attenuation_db(rp)                          # p=0.01%
        A_01  = rain_attenuation_db(rp; availability_pct = 99.9) # p=0.1%
        A_1   = rain_attenuation_db(rp; availability_pct = 99.0) # p=1%
        # 更高可用度（更小 p）对应更大雨衰
        @test A_001 > A_01 > A_1 > 0
        # 参数确实改变了结果（回归此前"死参数"bug）
        @test !isapprox(A_001, A_01; rtol = 1e-3)
    end

    @testset "低仰角垂直调整因子不再等同高仰角伪分支" begin
        # 构造仅仰角不同的两组参数；修复前两分支公式相同，
        # 修复后 v_0.01 随仰角变化，L_E 应不同。
        rp_hi = RainParameters(; frequency_ghz = 20.0, elevation_deg = 40.0,
            rain_rate_mm_h = 42.0, latitude_deg = 40.0)
        rp_lo = RainParameters(; frequency_ghz = 20.0, elevation_deg = 10.0,
            rain_rate_mm_h = 42.0, latitude_deg = 40.0)
        @test effective_path_length_km(rp_hi) != effective_path_length_km(rp_lo)
    end

    @testset "晴空雨衰为 0" begin
        rp0 = RainParameters(; frequency_ghz = 20.0, elevation_deg = 30.0,
            rain_rate_mm_h = 0.0)
        @test rain_attenuation_db(rp0) == 0.0
        @test rain_attenuation_db(rp0; availability_pct = 99.9) == 0.0
    end

    @testset "近天顶仰角不产生 NaN/Inf" begin
        rpz = RainParameters(; frequency_ghz = 20.0, elevation_deg = 89.0,
            rain_rate_mm_h = 42.0, latitude_deg = 40.0)
        A = rain_attenuation_db(rpz)
        @test isfinite(A) && A > 0
    end

    @testset "雨顶高度（P.839）分段" begin
        @test rain_height_km(0.0) == 5.0        # 热带
        @test rain_height_km(20.0) == 5.0       # |lat| <= 23
        @test rain_height_km(43.0) < 5.0        # 温带递减
    end
end

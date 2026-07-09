# ===== ISL 约束检查测试 =====
# 测试几何函数 + ISL 评估的完整调用链。

using Test
using SatelliteSimJulia

const ISL_CONSTRAINTS_LINK = SatelliteSimJulia.SatelliteSimCore.SatelliteSimLink
const distance_km = ISL_CONSTRAINTS_LINK.distance_km
const has_los = ISL_CONSTRAINTS_LINK.has_los
const propagation_delay_ms = ISL_CONSTRAINTS_LINK.propagation_delay_ms
const compute_rtn_coordinates = ISL_CONSTRAINTS_LINK.compute_rtn_coordinates
const compute_elevation_from_rtn = ISL_CONSTRAINTS_LINK.compute_elevation_from_rtn
const compute_azimuth_from_rtn = ISL_CONSTRAINTS_LINK.compute_azimuth_from_rtn
const evaluate_isl = ISL_CONSTRAINTS_LINK.evaluate_isl
const LEO_DEFAULTS = SatelliteSimJulia.LEO_DEFAULTS

@testset "ISL约束检查" begin
    # 模拟两颗卫星的位置和速度（ECI, km）
    # pos_a=(7000,0,0), vel_a=(0,7.5,0) → R=(1,0,0), T=(0,1,0), N=(0,0,1)
    # pos_b 放在右侧（N+ 方向），使右侧终端（terminal_id=4）通过方位角检查
    pos_a = (7000.0, 0.0, 0.0)
    pos_b = (7000.0, 100.0, 900.0)  # 100km ahead, 900km to the right
    vel_a = (0.0, 7.5, 0.0)
    vel_b = (0.0, 7.5, 0.001)       # 几乎同向，预计持续较长时间

    # 1. 基本距离检查
    d = distance_km(pos_a, pos_b)
    @test d > 0

    # 2. LOS 检查
    los = has_los(pos_a, pos_b)
    @test los  # 两颗卫星都在太空，应该可见

    # 3. 仰角检查
    r, t, n = compute_rtn_coordinates(pos_a, vel_a, pos_b)
    elev = compute_elevation_from_rtn(r, t, n)
    @test elev >= 0

    # 4. 方位角检查
    cos_psi = compute_azimuth_from_rtn(t, n)
    @test -1 <= cos_psi <= 1

    # 5. 完整 ISL 评估（使用右侧终端 terminal_id=4）
    constraints = LEO_DEFAULTS
    available, d2, los2, delay, details = evaluate_isl(
        pos_a, pos_b;
        constraints=constraints, vel_a=vel_a, vel_b=vel_b,
        terminal_id=4, time_horizon=300.0,
    )
    @test available     # 近距离同向 → 应该可用
    @test details.elevation_ok
    @test details.azimuth_ok
    @test details.duration_ok

    println("✅ ISL约束检查通过")
    println("   距离: $(round(d2, digits=1)) km")
    println("   时延: $(round(delay, digits=2)) ms")
    println("   仰角: $(round(details.elevation_deg, digits=1))°")
    println("  cos_psi: $(round(details.cos_psi, digits=3))")
    println("   持续: $(round(details.duration_s, digits=1)) s")
end

@testset "RTN几何边界" begin
    # 两颗卫星在同一位置 → 相对位置为零向量
    pos = (7000.0, 0.0, 0.0)
    vel = (0.0, 7.5, 0.0)
    r, t, n = compute_rtn_coordinates(pos, vel, pos)
    @test isapprox(r, 0.0, atol=1e-10)
    @test isapprox(t, 0.0, atol=1e-10)
    @test isapprox(n, 0.0, atol=1e-10)
    # 同时验证仰角和方位角在重合时的退化行为
    elev = compute_elevation_from_rtn(r, t, n)
    @test isapprox(elev, 90.0)  # 重合 → 仰角 90°
    cos_psi = compute_azimuth_from_rtn(t, n)
    @test isapprox(cos_psi, 1.0, atol=1e-10)  # 重合 → cos_psi = 1

    # 目标在正前方（T+ 方向）
    target_ahead = (7000.0, 100.0, 0.0)
    r, t, n = compute_rtn_coordinates(pos, vel, target_ahead)
    @test abs(t) > abs(r) && abs(t) > abs(n)  # T 分量最大
    elev = compute_elevation_from_rtn(r, t, n)
    @test isapprox(elev, 0.0, atol=1e-10)     # 同高度 → 仰角 ≈ 0°
    cos_psi = compute_azimuth_from_rtn(t, n)
    @test isapprox(cos_psi, 0.0, atol=1e-10)  # 正前方 → n=0 → cos_psi=0

    # 目标在正右侧（N+ 方向）
    target_right = (7000.0, 0.0, 100.0)
    r, t, n = compute_rtn_coordinates(pos, vel, target_right)
    @test abs(n) > abs(r) && abs(n) > abs(t)  # N 分量最大
    cos_psi = compute_azimuth_from_rtn(t, n)
    @test isapprox(cos_psi, 1.0, atol=1e-10)  # 正右侧 → n 占主导 → cos_psi=1

    # 验证速度变化不影响 RTN 轴方向（只旋转时推导应在同一轨道）
    vel2 = (0.0, 7.5, 0.5)  # 速度有 Z 分量
    r2, t2, n2 = compute_rtn_coordinates(pos, vel2, target_ahead)
    @test abs(r2 - r) < 0.1  # R 轴只取决于位置，应几乎不变
end

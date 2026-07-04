# ===== HPOP 数值积分传播器（方案 E）=====
#
# 用 OrdinaryDiffEq 的 DP8 求解器做二体+J2 摄动的数值积分。
# 作为解析传播器（TwoBody/J2/J4）的精度基准（truth）。
#
# 力模型：二体引力 + J2 地球扁率摄动（一阶球谐）
#   a = -μ/r³ · r + J2 加速度项
#
# J2 加速度（ECI/ECEF 通用，球坐标）：
#   a_J2_x = -3/2 · J2 · μ · R²/r⁵ · x · (1 - 5z²/r²)
#   a_J2_y = -3/2 · J2 · μ · R²/r⁵ · y · (1 - 5z²/r²)
#   a_J2_z = -3/2 · J2 · μ · R²/r⁵ · z · (3 - 5z²/r²)
#
# 这比解析 J2 传播器精度更高（解析 J2 只有长期漂移，数值积分含全摄动）。
# 不与可微链路兼容（ODE 求解器不可微）——仅用作离线 truth。

using OrdinaryDiffEq
using LinearAlgebra: norm

export HPOPPropagator, propagate_hpop

const J2_CONST = 1.0826261732367e-3

"""
    HPOPPropagator

高精度数值积分传播器（二体+J2），用作 truth 基准。

用 DP8（Dormand-Prince 8阶）求解器，相对精度 1e-12。
比解析 J2 传播器精度更高（含完整 J2 摄动，非仅长期项）。
"""
struct HPOPPropagator end

"""
    _j2_acceleration(r, v, μ, R, J2) -> SVector{3}

J2 摄动加速度（ECI 坐标系，z 轴 = 地球自转轴）。
"""
function _j2_acceleration(r, μ, R, J2)
    x, y, z = r[1], r[2], r[3]
    r_mag = sqrt(x^2 + y^2 + z^2)
    r2 = r_mag^2
    r5 = r2^2 * r_mag

    factor = -1.5 * J2 * μ * R^2 / r5
    z2_r2 = z^2 / r2

    ax = factor * x * (1 - 5 * z2_r2)
    ay = factor * y * (1 - 5 * z2_r2)
    az = factor * z * (3 - 5 * z2_r2)

    return (ax, ay, az)
end

"""
    propagate_hpop(elems, tspan) -> Array{Float64,3}

用 HPOP 数值积分传播一组 KeplerianElements，返回 ECEF 位置矩阵 (N×T×3 km)。

这是精度基准（truth）——用于验证 TwoBody/J2/J4 解析传播器的误差。
"""
function propagate_hpop(
    elems::Vector{SatelliteToolbox.KeplerianElements},
    tspan::Vector{Float64},
)::Array{Float64,3}
    μ = SatelliteSimFoundation.MU_KM3_S2 * 1e9  # km³/s² → m³/s³（ODE 用 SI）
    R = SatelliteSimFoundation.WGS84_EQUATORIAL_RADIUS_KM * 1000  # km → m

    N = length(elems)
    M = length(tspan)
    pos_km = zeros(N, M, 3)

    for i in 1:N
        el = elems[i]
        # 从 KeplerianElements 提取初始状态（m, m/s）
        a = el.a  # 半长轴 (m)
        e = el.e
        i_inc = el.i
        Ω = el.Ω
        ω = el.ω
        f = el.f  # 真近点角

        # 真近点角 → 位置速度（perifocal → ECI）
        p = a * (1 - e^2)
        r_pf = p / (1 + e * cos(f))
        x_pf = r_pf * cos(f)
        y_pf = r_pf * sin(f)

        # 速度（perifocal）
        v_factor = sqrt(μ / p)
        vx_pf = -v_factor * sin(f)
        vy_pf = v_factor * (e + cos(f))

        # perifocal → ECI（3-1-3 旋转：Ω, i, ω）
        cΩ, sΩ = cos(Ω), sin(Ω)
        ci, si = cos(i_inc), sin(i_inc)
        cω, sω = cos(ω), sin(ω)

        x_eci = (cΩ*cω - sΩ*sω*ci) * x_pf + (-cΩ*sω - sΩ*cω*ci) * y_pf
        y_eci = (sΩ*cω + cΩ*sω*ci) * x_pf + (-sΩ*sω + cΩ*cω*ci) * y_pf
        z_eci = (sω*si) * x_pf + (cω*si) * y_pf

        vx_eci = (cΩ*cω - sΩ*sω*ci) * vx_pf + (-cΩ*sω - sΩ*cω*ci) * vy_pf
        vy_eci = (sΩ*cω + cΩ*sω*ci) * vx_pf + (-sΩ*sω + cΩ*cω*ci) * vy_pf
        vz_eci = (sω*si) * vx_pf + (cω*si) * vy_pf

        # ODE: ẋ=v, v̇=-μ/r³·r + J2
        function ode!(du, u, p, t)
            r = (u[1], u[2], u[3])
            v = (u[4], u[5], u[6])
            r_mag = sqrt(r[1]^2 + r[2]^2 + r[3]^2)

            # 二体引力
            factor_grav = -μ / r_mag^3
            ax = factor_grav * r[1]
            ay = factor_grav * r[2]
            az = factor_grav * r[3]

            # J2 摄动
            j2 = _j2_acceleration(r, μ, R, J2_CONST)
            ax += j2[1]
            ay += j2[2]
            az += j2[3]

            du[1], du[2], du[3] = v
            du[4], du[5], du[6] = ax, ay, az
        end

        u0 = [x_eci, y_eci, z_eci, vx_eci, vy_eci, vz_eci]
        tspan_ode = (tspan[1], tspan[end])

        prob = ODEProblem(ode!, u0, tspan_ode)
        sol = solve(prob, DP8(); reltol=1e-12, abstol=1e-12, saveat=tspan)

        for j in 1:M
            # ECI → ECEF：绕 z 轴旋转 -GMST
            gmst = SatelliteSimFoundation.OMEGA_EARTH * sol.t[j]
            cg, sg = cos(gmst), sin(gmst)
            x_eci_t = sol.u[j][1]
            y_eci_t = sol.u[j][2]
            z_eci_t = sol.u[j][3]
            pos_km[i, j, 1] = ( cg * x_eci_t + sg * y_eci_t) / 1000
            pos_km[i, j, 2] = (-sg * x_eci_t + cg * y_eci_t) / 1000
            pos_km[i, j, 3] = z_eci_t / 1000
        end
    end

    return pos_km
end

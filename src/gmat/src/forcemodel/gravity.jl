# ===== 球谐重力场力模型（GMAT GravityField/HarmonicField）=====
#
# 地球引力加速度 = 中心引力 + 球谐摄动。
# GMAT 支持完整 EGM96（70×70），本包先实现解析 J2/J4（精确），高阶标为扩展。
#
# 参考：Vallado《Fundamentals of Astrodynamics and Applications》式 (8-25)~(8-27)
# 单位：SI（m, m/s, m/s²）

using SatelliteSimFoundation: WGS84_EQUATORIAL_RADIUS_KM, MU_KM3_S2

export GravityField, acceleration

const R_EARTH_M = WGS84_EQUATORIAL_RADIUS_KM * 1000.0      # m
const MU_M3_S2 = MU_KM3_S2 * 1e9                            # m³/s²
const J2_CONST = 1.0826261732367e-3
const J4_CONST = -1.65597e-6

"""
    GravityField

地球球谐重力场力模型。

# 字段
- `degree::Int`: 球谐阶数（2=J2, 4=J4, ≥4 需系数表，标为扩展）
- `order::Int`: 球谐次（当前解析 J2/J4 不用 order，保留接口）
"""
struct GravityField <: AbstractForceModel
    degree::Int
    order::Int
end

# 便捷构造
GravityField(; degree::Int=2) = GravityField(degree, 0)
J2Gravity() = GravityField(2, 0)
J4Gravity() = GravityField(4, 0)

"""
    acceleration(g::GravityField, r, v, t, sc) -> SVector{3}

计算地球引力加速度（中心引力 + J2/J4 摄动）。
"""
function acceleration(g::GravityField, r, v, t, sc)
    x, y, z = r[1], r[2], r[3]
    r_mag = sqrt(x^2 + y^2 + z^2)
    r2 = r_mag^2
    r3 = r2 * r_mag          # r³（中心引力用）
    r5 = r2^2 * r_mag        # r⁵（J2 用）
    r7 = r5 * r2             # r⁷（J4 用）

    # 中心引力 -μ/r³ · r  （注意：是 r³ 不是 r⁵）
    factor_c = -MU_M3_S2 / r3
    ax = factor_c * x
    ay = factor_c * y
    az = factor_c * z

    # J2 摄动（degree >= 2）
    if g.degree >= 2
        z2_r2 = z^2 / r2
        factor_j2 = -1.5 * J2_CONST * MU_M3_S2 * R_EARTH_M^2 / r5
        ax += factor_j2 * x * (1 - 5 * z2_r2)
        ay += factor_j2 * y * (1 - 5 * z2_r2)
        az += factor_j2 * z * (3 - 5 * z2_r2)
    end

    # J4 摄动（degree >= 4）
    if g.degree >= 4
        z2_r2 = z^2 / r2
        z4_r4 = z2_r2^2
        # J4 项：(35z⁴/r⁴ - 30z²/r² + 3)
        factor_j4 = (15.0/8.0) * J4_CONST * MU_M3_S2 * R_EARTH_M^4 / r7
        poly = 35 * z4_r4 - 30 * z2_r2 + 3
        ax += factor_j4 * x * poly
        ay += factor_j4 * y * poly
        # z 分量的 J4 系数不同：(35z⁴/r⁴ - 30z²/r² + 3) - (140z⁴/r⁴/3 - 20z²/r²)
        az += factor_j4 * z * (poly - (140/3 * z4_r4 - 20 * z2_r2))
    end

    return SVector(ax, ay, az)
end

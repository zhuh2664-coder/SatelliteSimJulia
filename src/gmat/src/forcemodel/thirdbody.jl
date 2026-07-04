# ===== 第三体摄动力模型（GMAT ThirdBody）=====
#
# 第三体（日/月）引力摄动。简化版：用解析平位置（J2000）而非星历（SPICE）。
# 加速度 = μ_body · (r_body/sat→body³ - r_body/origin→body³)
#
# 参考：Vallado 式 (8-46)，点质量第三体摄动。

export ThirdBody, SUN_MU, MOON_MU, body_position

# 日月引力参数（m³/s²）
const SUN_MU = 1.32712440018e20    # 太阳 GM
const MOON_MU = 4.902798e12        # 月球 GM

"""
    ThirdBody

第三体摄动力模型（日或月）。

# 字段
- `body::Symbol`: :sun 或 :moon
"""
struct ThirdBody <: AbstractForceModel
    body::Symbol
end

ThirdBody() = ThirdBody(:sun)

"""
    body_position(body::Symbol, t::Real) -> SVector{3}

第三体在 ECI（地心）系的位置（m）。简化解析平位置。
t = 从 J2000 起的秒数。

注意：这是粗略平位置，精度不如 SPICE 星历，适合摄动量级估算。
高精度需求应替换为 SPICE 星历。
"""
function body_position(body::Symbol, t::Real)
    days = t / 86400.0  # 秒 → 天
    if body == :sun
        # 太阳平黄经约 0.9856°/天，距离 1.496e11 m
        lambda = deg2rad(280.46 + 0.9856474 * days)  # 平黄经
        r_sun = 1.495978707e11  # 1 AU (m)
        # 黄道面近似（忽略黄赤倾角，简化）
        return SVector(r_sun*cos(lambda), r_sun*sin(lambda), 0.0)
    elseif body == :moon
        # 月球平黄经约 13.176°/天，距离 3.844e8 m
        lambda = deg2rad(218.32 + 13.176396 * days)
        r_moon = 3.844e8  # m
        # 月球轨道倾角约 28.5°（简化用 0）
        return SVector(r_moon*cos(lambda), r_moon*sin(lambda), 0.0)
    else
        error("未知第三体: $body（应为 :sun 或 :moon）")
    end
end

"""
    acceleration(tb::ThirdBody, r, v, t, sc) -> SVector{3}

第三体摄动加速度（点质量模型）。
"""
function acceleration(tb::ThirdBody, r, v, t, sc)
    mu_body = tb.body == :sun ? SUN_MU : MOON_MU
    r_body = body_position(tb.body, t)  # 第三体相对地心位置

    # 卫星→第三体 向量
    r_sat_to_body = r_body - r
    r_mag = norm(r_sat_to_body)
    r_mag3 = r_mag^3

    # 地心→第三体 向量的模
    r_body_mag = norm(r_body)
    r_body_mag3 = r_body_mag^3

    # 摄动加速度 = μ_body · (r_sat→body/r³ - r_body/r_body³)
    return mu_body * (r_sat_to_body / r_mag3 - r_body / r_body_mag3)
end

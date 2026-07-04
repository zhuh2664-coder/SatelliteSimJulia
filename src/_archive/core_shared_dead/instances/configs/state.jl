# ===== 卫星初始状态预设 =====
# 轨道状态配置，供 build_satellite 的 state 参数使用。

export StateConfig

Base.@kwdef struct StateConfig
    x::Float64 = 0.0
    y::Float64 = 0.0
    z::Float64 = 0.0
    vx::Float64 = 0.0
    vy::Float64 = 0.0
    vz::Float64 = 0.0
    status::LegacyEntities.SatelliteStatus = LegacyEntities.ACTIVE
end

# ── 示例轨道状态 ──
const ORBIT_EQUATORIAL_A = StateConfig(; x=7000.0, vy=7.5)
const ORBIT_EQUATORIAL_B = StateConfig(; y=7000.0, vx=-7.5)

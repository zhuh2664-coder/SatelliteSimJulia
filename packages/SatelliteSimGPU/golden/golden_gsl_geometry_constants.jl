# 物理常量（从 geometry.jl 拆出，纯基础，无领域意见）
# 几何函数（has_los/distance_km 等）留在 Core，它们是链路评估原语。

export SPEED_OF_LIGHT_KM_S, WGS84_EQUATORIAL_RADIUS_KM, MU_KM3_S2, OMEGA_EARTH

const SPEED_OF_LIGHT_KM_S = 299_792.458   # km/s
const WGS84_EQUATORIAL_RADIUS_KM = 6378.137  # WGS84 赤道半径 (km)
const MU_KM3_S2 = 398600.4415   # Earth gravitational parameter (km³/s²)
const OMEGA_EARTH = 7.2921150e-5  # Earth rotation rate (rad/s)

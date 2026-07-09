"""
    参考系与坐标转换模块

本文件定义项目内部使用的参考系类型、坐标状态容器，以及 TEME -> ECEF -> WGS84 经纬高的转换。

轨道传播器输出 TEME 坐标；网络层与地面站几何计算需要 ECEF/ITRF 坐标；
可视化、星下点分析、地理解释则需要 WGS84 经纬高。本模块提供统一的转换接口，
使上层代码不必直接处理 SatelliteToolbox 的底层矩阵与单位细节。

# [算法说明]
# TEME（True Equator Mean Equinox）坐标系：这是一种准惯性坐标系，其X轴指向春分点，
# XY平面为真赤道面。SGP4算法直接在TEME坐标系中输出卫星位置和速度。
# 该坐标系的优点是：①与SGP4算法输出直接对应，避免额外转换；②简化轨道传播计算。
#
# ECEF（Earth-Centered, Earth-Fixed）坐标系：这是一种地固坐标系，随地球一起旋转。
# 其X轴指向本初子午线（格林威治方向），Z轴指向北极。优点是：①地面站位置固定不变；
# ②便于计算卫星与地面站的几何关系（距离、仰角等）。
#
# 为什么需要TEME到ECEF转换：
# 1. SGP4算法在TEME坐标系中计算卫星轨道，但网络层需要计算卫星与地面站的几何关系。
# 2. 地面站固定在地球表面，在ECEF坐标系中坐标恒定，而在TEME坐标系中随时间变化。
# 3. 为统一计算基准，必须将卫星位置从TEME转换到ECEF。
#
# WGS84经纬高坐标系：这是一种地理坐标系，用经纬度和高度描述位置。
# 优点是直观易懂，便于可视化和地理解释。
#
# 转换链条：TEME -> ECEF -> WGS84经纬高
# 这个链条对应了从轨道物理到网络几何再到地理解释的完整过程。

# 依赖
- SatelliteToolbox：TEME/ECEF 旋转矩阵、ECEF 到经纬高的转换、儒略日计算。
- SimulationTimeGrid、SimulationEpoch（time.jl）：获取真实 DateTime。
"""

import SatelliteToolbox

export AbstractFrameTransform, SimpleTemeToGeodeticTransform
export CartesianState, GeodeticPosition
export ECEF, ECI, TEME
export ecef_to_geodetic

"""
    AbstractFrameTransform

坐标转换接口的抽象基类型。

所有具体坐标转换实现都应继承此类型。后续如果需要更高精度的 IERS 地球自转参数、
极移、UT1-UTC 等模型，可以新增一个具体 transform 类型，而不是改写上层星历和链路代码。
"""
abstract type AbstractFrameTransform end

"""
    SimpleTemeToGeodeticTransform <: AbstractFrameTransform

当前项目里最小可用的 TEME -> ECEF/经纬高转换实现。

它负责把 SGP4 输出的 TEME 状态转换到地固坐标系，再进一步转换为 WGS84 经纬高。
"""
struct SimpleTemeToGeodeticTransform <: AbstractFrameTransform end

"""
    ReferenceFrame

项目内部使用的参考系枚举。

- `TEME`：SGP4 常见输出坐标系。
- `ECI`：地心惯性坐标系。
- `ECEF`：地固坐标系，适合和地面站做几何计算。
- `ITRF`：国际地球参考框架。
- `WGS84_LLA`：经纬高形式，常用于地面站、用户终端和可视化。
"""
@enum ReferenceFrame begin
    TEME
    ECI
    ECEF
    ITRF
    WGS84_LLA
end

"""
    CartesianState

笛卡尔坐标系下的位置和速度状态。

# 字段
- `frame::ReferenceFrame`：参考系，明确说明这组三维数属于哪个参考系，避免把 TEME 和 ECEF 混在一起计算。
- `position_km::NTuple{3,Float64}`：三维位置，单位 km。
- `velocity_km_s::Union{Nothing,NTuple{3,Float64}}`：三维速度，单位 km/s，可选。
"""
struct CartesianState
    frame::ReferenceFrame
    position_km::NTuple{3,Float64}
    velocity_km_s::Union{Nothing,NTuple{3,Float64}}
end

"""
    GeodeticPosition

WGS84 经纬高位置。

地面站、POP、用户终端通常天然用经纬度和高度描述。网络层计算 GSL 时，
会把这种地理位置转换成 ECEF 向量，再和卫星 ECEF 位置计算距离与仰角。

# 字段
- `latitude_deg::Float64`：纬度，单位 degree，范围 [-90, 90]。
- `longitude_deg::Float64`：经度，单位 degree，范围 [-180, 180]。
- `altitude_km::Float64`：高度，单位 km。地面站通常是 0 或接近 0；卫星星下点会带有卫星高度。
"""
struct GeodeticPosition
    latitude_deg::Float64
    longitude_deg::Float64
    altitude_km::Float64

    function GeodeticPosition(latitude_deg::Real, longitude_deg::Real, altitude_km::Real)
        -90 <= latitude_deg <= 90 || throw(ArgumentError("latitude_deg must be in [-90, 90]"))
        -180 <= longitude_deg <= 180 || throw(ArgumentError("longitude_deg must be in [-180, 180]"))
        return new(Float64(latitude_deg), Float64(longitude_deg), Float64(altitude_km))
    end
end

"""
    target_datetime(time_grid::SimulationTimeGrid, elapsed_s::Int) -> DateTime

把仿真时间网格中的 elapsed_s 转成真实 DateTime。

轨道传播、地球自转角和 TEME -> ECEF 转换都需要知道"这是 epoch 后的哪个真实时刻"。
"""
function target_datetime(time_grid::SimulationTimeGrid, elapsed_s::Int)::DateTime
    return time_grid.epoch.instant + Dates.Millisecond(1000 * elapsed_s)
end

"""
    julian_day(time::DateTime) -> Float64

把 DateTime 转换为儒略日。

SatelliteToolbox 的参考系转换函数使用儒略日作为时间输入。
"""
julian_day(time::DateTime)::Float64 = SatelliteToolbox.date_to_jd(time)

"""
    teme_to_ecef(transform::SimpleTemeToGeodeticTransform, cartesian::CartesianState, time::DateTime) -> CartesianState

将 SGP4 输出的 TEME 笛卡尔状态转换到 ECEF。

# [算法说明]
# TEME到ECEF转换的数学原理：
# 设P_TEME = [x, y, z]ᵀ为TEME坐标系中的位置向量，
# P_ECEF = [X, Y, Z]ᵀ为ECEF坐标系中的位置向量。
# 转换公式：P_ECEF = R * P_TEME
# 其中R为旋转矩阵，表示地球自转。
#
# 旋转矩阵R的构造：
# R = R_z(-θ) * R_x(ε) * R_y(ω)
# 其中：
# - θ = GMST（格林威治恒星时）：地球自转角度
# - ε = 黄赤交角：约23.44°
# - ω = 极移角：微小修正（本简化实现忽略）
#
# 速度转换：
# V_ECEF = R * V_TEME + ω × P_ECEF
# 其中ω为地球自转角速度向量。
# 注意：本实现忽略了ω × P_ECEF项，因为对于低轨道卫星，该影响较小。

这一步是轨道层和网络层之间非常关键的桥：

    SGP4/TLE -> TEME 位置速度 -> ECEF 位置速度 -> ISL/GSL 几何计算

地面站固定在地球表面，天然属于地固坐标/经纬高描述。因此计算 GSL 时，必须把卫星位置
转到 ECEF，或者把地面站转到同一参考系。本项目选择前者。
"""
function teme_to_ecef(
    ::SimpleTemeToGeodeticTransform,
    cartesian::CartesianState,
    time::DateTime,
)::CartesianState
    # 防止误把已经是 ECEF 或其他参考系的状态再次当作 TEME 转换。
    cartesian.frame == TEME ||
        throw(ArgumentError("SimpleTemeToGeodeticTransform requires a TEME CartesianState"))

    # [算法说明]
    # TEME到ECEF的转换本质上是地球自转的坐标变换。
    # 旋转矩阵R表示从惯性系（TEME）到地固系（ECEF）的旋转，
    # 其主要分量包括：①地球自转角θ（格林威治恒星时）；
    # ②极移修正（微小调整，本简化实现忽略）；③章动和岁差修正（同样简化）。
    #
    # r_eci_to_ecef函数计算的旋转矩阵R满足：
    #   P_ECEF = R * P_TEME
    # 其中P_ECEF是ECEF坐标，P_TEME是TEME坐标。
    #
    # 使用SatelliteToolbox提供成熟实现的原因：
    # 1. 避免手动实现复杂的地球自转模型；
    # 2. 确保与国际标准一致；
    # 3. 处理边界情况和数值稳定性。
    rotation = SatelliteToolbox.r_eci_to_ecef(
        SatelliteToolbox.TEME(),
        SatelliteToolbox.PEF(),
        julian_day(time),
    )

    # SatelliteToolbox 的底层函数按 m / m/s 工作，所以这里从 km / km/s 转到 m / m/s。
    position_m = rotation * collect(cartesian.position_km .* 1000)
    velocity_m_s = if cartesian.velocity_km_s === nothing
        nothing
    else
        rotation * collect(cartesian.velocity_km_s .* 1000)
    end

    # 项目内部统一保留 km / km/s，转换完成后再从 m / m/s 转回来。
    return CartesianState(
        ECEF,
        Tuple(Float64(x / 1000) for x in position_m),
        velocity_m_s === nothing ? nothing : Tuple(Float64(x / 1000) for x in velocity_m_s),
    )
end

"""
    ecef_to_geodetic(cartesian::CartesianState) -> GeodeticPosition

将 ECEF/ITRF 笛卡尔状态转换为 WGS84 经纬高。

# [算法说明]
# WGS84（World Geodetic System 1984）是国际通用的地球椭球体模型。
# 将笛卡尔坐标（X, Y, Z）转换为地理坐标（纬度φ, 经度λ, 高度h）的算法如下：
#
# 1. 经度计算：λ = atan2(Y, X)
#    这是直接计算，因为X轴指向本初子午线。
#
# 2. 纬度和高度计算：需要迭代求解（Bowring方法或更精确的迭代算法）：
#    a. 初始估计：p = sqrt(X² + Y²)，φ₀ = atan2(Z, p * (1-e²))
#    b. 迭代计算：
#       - N(φ) = a / sqrt(1 - e²sin²(φ))  # 卯酉圈曲率半径
#       - h = p / cos(φ) - N(φ)
#       - φ = atan2(Z, p * (1 - e²N(φ)/(N(φ)+h)))
#    c. 收敛条件：|φ_new - φ_old| < ε
#
# 其中：a = 6378.137 km（长半轴），e² = 0.00669437999014（第一偏心率平方）
#
# 为什么使用迭代法：
# 1. 椭球体模型没有简单的解析解；
# 2. 迭代法收敛速度快（通常3-5次迭代）；
# 3. 数值稳定，适用于全球范围。

这通常用于星下点、可视化和地理解释。GSL 核心计算一般直接使用 ECEF 向量，
因为距离和仰角计算更适合在三维地固坐标里完成。
"""
function ecef_to_geodetic(cartesian::CartesianState)::GeodeticPosition
    cartesian.frame == ECEF || cartesian.frame == ITRF ||
        throw(ArgumentError("ecef_to_geodetic requires ECEF or ITRF CartesianState"))

    # SatelliteToolbox 接收单位为 m 的 ECEF 位置，返回纬度/经度弧度和高度 m。
    latitude_rad, longitude_rad, altitude_m = SatelliteToolbox.ecef_to_geodetic(
        collect(cartesian.position_km .* 1000),
    )

    # 项目对外使用 degree 和 km，便于配置、可视化和论文解释。
    return GeodeticPosition(rad2deg(latitude_rad), rad2deg(longitude_rad), altitude_m / 1000)
end

"""
    geodetic_position(transform, cartesian, time) -> GeodeticPosition

一步完成 TEME -> ECEF -> WGS84 经纬高。

这个函数适合在需要星下点或可视化标签时使用；如果后续要计算链路距离和仰角，
通常会先保留 ECEF 笛卡尔状态。
"""
function geodetic_position(
    transform::SimpleTemeToGeodeticTransform,
    cartesian::CartesianState,
    time::DateTime,
)::GeodeticPosition
    return ecef_to_geodetic(teme_to_ecef(transform, cartesian, time))
end

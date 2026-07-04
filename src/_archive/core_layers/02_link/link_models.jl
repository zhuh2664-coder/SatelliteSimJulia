

"""
    网络层 / 物理链路评估模块

本模块基于轨道层输出的 `ConstellationEphemeris`（星座星历），对 topology.jl
生成的静态 ISL 候选图以及地面站到卫星的 GSL（Ground-Satellite Link，地卫链路）
进行逐时间片的物理评估。

# 主要功能
1. ISL（星间链路）物理评估：
   - 计算卫星间的距离
   - 计算光传播时延（时延 = 距离 / 光速）
   - 判断视距（Line of Sight, LOS）：检测地球是否遮挡视线
   - 根据距离和视距约束判断链路是否可用
   - 输出 `ISLPhysicalLinkSeries`：所有时间片上所有 ISL 链路的物理样本序列

2. GSL（地卫链路）物理评估：
   - 计算地面站到卫星的距离
   - 计算光传播时延
   - 计算地面站处卫星仰角
   - 根据仰角计算链路容量（支持多种容量模型）
   - 根据最小仰角约束和距离约束判断链路是否可用
   - 输出 `GSLPhysicalLinkSeries`：所有时间片上地面站到所有卫星的物理样本序列

# 容量模型
本模块支持三种 GSL 容量模型，用于模拟不同仰角下的链路容量变化：

- `FixedGSLCapacityModel`（固定容量模型）：容量与仰角无关，始终返回固定值。
- `ElevationPiecewiseGSLCapacityModel`（分段线性模型）：容量随仰角从截止仰角到饱和仰角线性增长。
- `ElevationExponentialGSLCapacityModel`（指数模型）：容量随仰角按指数趋近基准容量。

# 物理约束
- ISL 约束：最大距离限制（max_range_km）、视距要求（require_line_of_sight）。
- GSL 约束：最小仰角（min_elevation_deg）、最大距离限制（max_range_km）。

# 坐标系
- 位置计算使用 ECEF（Earth-Centered, Earth-Fixed）坐标系
- 仰角计算使用 NED（North-East-Down）局部坐标系

# 下游模块
- access.jl：接入选择模块，根据物理链路状态选择接入卫星
- routing.jl：路由模块，使用传播时延计算最短时延路由

# 算法说明

## 视距（Line of Sight, LOS）判断算法
视距判断是 ISL 可用性的关键约束。算法将地球简化为球体，检查卫星 A 到卫星 B 的
连线段是否与地球球体相交。若相交则链路被地球遮挡，标记为不可用。

算法步骤：
1. 设线段起点为 a（卫星 A 位置），终点为 b（卫星 B 位置），地心为原点 O
2. 计算线段方向向量 segment = b - a
3. 求地心到线段上最近点的投影参数 t：
   t = clamp(-dot(a, segment) / |segment|², 0, 1)
   该公式利用向量投影将地心投影到线段上，并截断到 [0,1] 范围内
4. 最近点坐标为 closest = a + t * segment
5. 若 |closest| > R_earth，则视线不被遮挡

## 仰角（Elevation Angle）计算算法
仰角用于衡量卫星相对于地面站地平面的高度角，是 GSL 可用性的关键指标。

算法步骤：
1. 将卫星 ECEF 坐标转换到地面站局部 NED（北-东-地）坐标系
2. NED 系中，z 轴指向地心方向（向下），-z 指向天顶（向上）
3. 计算天底角（nadir angle）：卫星方向与天顶方向的夹角
   nadir_angle = arccos(-satellite_ned_z / |satellite_ned|)
4. 仰角 = 90° - 天底角

## GSL 容量模型
容量模型用于模拟不同仰角下链路可用带宽的变化。

### 分段线性模型
将仰角范围分为三段：
- 低于截止仰角：仅保留信令容量（保持最低通信能力）
- 截止仰角到饱和仰角：线性插值
  C = C_signal + (elevation - cutoff) / (saturation - cutoff) * (C_base - C_signal)
- 高于饱和仰角：获得完整基准容量

### 指数模型
容量按指数方式趋近基准容量：
C = C_signal + (C_base - C_signal) * (1 - e^(-rate * Δelevation))
其中 Δelevation = elevation - cutoff_elevation_deg
该模型更真实地反映了仰角增加时信号质量的边际递减效应

## ISL 可用性判断
链路可用性由距离约束和视距约束共同决定：
1. 距离约束：链路距离不得超过配置的最大允许距离
2. 视距约束：若配置要求视距，则两点间连线不得被地球遮挡
只有两个条件同时满足时，链路才标记为可用
"""

# export AbstractGSLCapacityModel, FixedGSLCapacityModel, ElevationPiecewiseGSLCapacityModel, ElevationExponentialGSLCapacityModel  # 收窄：无下游消费者
export ISLPhysicalLinkSample, ISLPhysicalLinkSeries
export GSLPhysicalLinkSample, GSLPhysicalLinkSeries
# export evaluate_gsl_sample  # 收窄：无下游消费者

using LinearAlgebra
import SatelliteAnalysis
import SatelliteToolbox

# [物理常数]
# 光速（km/s），用于计算光传播时延：时延 = 距离 / 光速
# 取值：CODATA 2018 推荐值

# [地球模型]
# WGS84 参考椭球体赤道半径（km），用于地球遮挡判断
# 取值：WGS84 坐标系标准值
# 在 LOS 判断中将地球简化为球体，使用赤道半径作为近似

"""
    AbstractGSLCapacityModel

GSL 容量模型的抽象类型，所有具体的容量模型（固定、分段线性、指数）
都必须继承此类型，以实现统一的多态接口。
"""
abstract type AbstractGSLCapacityModel end

"""
    FixedGSLCapacityModel <: AbstractGSLCapacityModel

固定容量 GSL 容量模型，与仰角无关。

# 字段
- `capacity_mbps::Float64`: 固定容量（Mbps），默认 `Inf`。
"""
struct FixedGSLCapacityModel <: AbstractGSLCapacityModel
    capacity_mbps::Float64

    function FixedGSLCapacityModel(capacity_mbps::Real = Inf)
        capacity_mbps >= 0 || throw(ArgumentError("capacity_mbps must be non-negative"))
        return new(Float64(capacity_mbps))
    end
end

"""
    ElevationPiecewiseGSLCapacityModel <: AbstractGSLCapacityModel

分段线性 GSL 容量模型：容量随仰角从截止仰角到饱和仰角线性增长。

# 字段
- `base_capacity_mbps::Float64`: 饱和后的基准容量（Mbps）。
- `cutoff_elevation_deg::Float64`: 低于该仰角时仅保留信令容量。
- `saturation_elevation_deg::Float64`: 达到或超过该仰角时获得完整基准容量。
- `signaling_capacity_mbps::Float64`: 低于截止仰角时的信令容量（Mbps）。
"""
struct ElevationPiecewiseGSLCapacityModel <: AbstractGSLCapacityModel
    base_capacity_mbps::Float64
    cutoff_elevation_deg::Float64
    saturation_elevation_deg::Float64
    signaling_capacity_mbps::Float64

    function ElevationPiecewiseGSLCapacityModel(;
        base_capacity_mbps::Real,
        cutoff_elevation_deg::Real = 25,  # 默认截止仰角：低于此仰角时仅保留信令容量
        saturation_elevation_deg::Real = 45,  # 默认饱和仰角：达到或超过此仰角时获得完整基准容量
        signaling_capacity_mbps::Real = 0,  # 默认信令容量：低于截止仰角时的容量
    )
        isfinite(base_capacity_mbps) ||
            throw(ArgumentError("base_capacity_mbps must be finite"))
        base_capacity_mbps >= 0 ||
            throw(ArgumentError("base_capacity_mbps must be non-negative"))
        -90 <= cutoff_elevation_deg <= 90 ||
            throw(ArgumentError("cutoff_elevation_deg must be in [-90, 90]"))
        -90 <= saturation_elevation_deg <= 90 ||
            throw(ArgumentError("saturation_elevation_deg must be in [-90, 90]"))
        # 饱和仰角必须大于截止仰角，否则模型无意义
        saturation_elevation_deg > cutoff_elevation_deg ||
            throw(ArgumentError("saturation_elevation_deg must be greater than cutoff_elevation_deg"))
        signaling_capacity_mbps >= 0 ||
            throw(ArgumentError("signaling_capacity_mbps must be non-negative"))
        # 信令容量不能超过基准容量
        signaling_capacity_mbps <= base_capacity_mbps ||
            throw(ArgumentError("signaling_capacity_mbps must not exceed base_capacity_mbps"))
        return new(
            Float64(base_capacity_mbps),
            Float64(cutoff_elevation_deg),
            Float64(saturation_elevation_deg),
            Float64(signaling_capacity_mbps),
        )
    end
end

"""
    ElevationExponentialGSLCapacityModel <: AbstractGSLCapacityModel

指数平滑 GSL 容量模型：容量随仰角按指数趋近基准容量。

# 字段
- `base_capacity_mbps::Float64`: 饱和后的基准容量（Mbps）。
- `cutoff_elevation_deg::Float64`: 低于该仰角时仅保留信令容量。
- `growth_rate::Float64`: 指数增长率，控制容量随仰角上升的速度。
- `signaling_capacity_mbps::Float64`: 低于截止仰角时的信令容量（Mbps）。
"""
struct ElevationExponentialGSLCapacityModel <: AbstractGSLCapacityModel
    base_capacity_mbps::Float64
    cutoff_elevation_deg::Float64
    growth_rate::Float64
    signaling_capacity_mbps::Float64

    function ElevationExponentialGSLCapacityModel(;
        base_capacity_mbps::Real,
        cutoff_elevation_deg::Real = 25,  # 默认截止仰角：低于此仰角时仅保留信令容量
        growth_rate::Real = 0.1,  # 默认增长率：控制容量随仰角上升的速度
        signaling_capacity_mbps::Real = 0,  # 默认信令容量：低于截止仰角时的容量
    )
        isfinite(base_capacity_mbps) ||
            throw(ArgumentError("base_capacity_mbps must be finite"))
        base_capacity_mbps >= 0 ||
            throw(ArgumentError("base_capacity_mbps must be non-negative"))
        -90 <= cutoff_elevation_deg <= 90 ||
            throw(ArgumentError("cutoff_elevation_deg must be in [-90, 90]"))
        # 增长率必须为正数，确保容量随仰角上升而增加
        growth_rate > 0 || throw(ArgumentError("growth_rate must be positive"))
        signaling_capacity_mbps >= 0 ||
            throw(ArgumentError("signaling_capacity_mbps must be non-negative"))
        # 信令容量不能超过基准容量
        signaling_capacity_mbps <= base_capacity_mbps ||
            throw(ArgumentError("signaling_capacity_mbps must not exceed base_capacity_mbps"))
        return new(
            Float64(base_capacity_mbps),
            Float64(cutoff_elevation_deg),
            Float64(growth_rate),
            Float64(signaling_capacity_mbps),
        )
    end
end

"""
    ISLPhysicalLinkConfig

ISL 物理链路评估配置。

# 字段
- `max_range_km::Union{Nothing,Float64}`: 最大允许链路距离（km），为 `nothing` 时不限制。
- `earth_radius_km::Float64`: 地球半径（km），用于 LOS 遮挡判断。
- `capacity_mbps::Float64`: ISL 容量（Mbps）。
- `require_line_of_sight::Bool`: 是否要求视距无遮挡。
"""
struct ISLPhysicalLinkConfig
    max_range_km::Union{Nothing,Float64}
    earth_radius_km::Float64
    capacity_mbps::Float64
    require_line_of_sight::Bool

    function ISLPhysicalLinkConfig(;
        max_range_km::Union{Nothing,Real} = nothing,
        earth_radius_km::Real = WGS84_EQUATORIAL_RADIUS_KM,
        capacity_mbps::Real = Inf,
        require_line_of_sight::Bool = true,
    )
        max_range_km === nothing || max_range_km > 0 ||
            throw(ArgumentError("max_range_km must be positive when provided"))
        earth_radius_km > 0 || throw(ArgumentError("earth_radius_km must be positive"))
        capacity_mbps >= 0 || throw(ArgumentError("capacity_mbps must be non-negative"))
        return new(
            max_range_km === nothing ? nothing : Float64(max_range_km),
            Float64(earth_radius_km),
            Float64(capacity_mbps),
            require_line_of_sight,
        )
    end
end

"""
    GSLPhysicalLinkConfig{M<:AbstractGSLCapacityModel}

GSL 物理链路评估配置。

# 字段
- `min_elevation_deg::Float64`: 最小可接受仰角（度）。
- `max_range_km::Union{Nothing,Float64}`: 最大允许距离（km），为 `nothing` 时不限制。
- `capacity_model::M`: GSL 容量模型（固定、分段线性或指数）。

# 说明
- 构造时 `capacity_mbps` 与 `capacity_model` 不能同时提供。
"""
struct GSLPhysicalLinkConfig{M<:AbstractGSLCapacityModel}
    min_elevation_deg::Float64
    max_range_km::Union{Nothing,Float64}
    capacity_model::M

    function GSLPhysicalLinkConfig(;
        min_elevation_deg::Real = 25,
        max_range_km::Union{Nothing,Real} = nothing,
        capacity_mbps::Union{Nothing,Real} = nothing,
        capacity_model::Union{Nothing,AbstractGSLCapacityModel} = nothing,
    )
        -90 <= min_elevation_deg <= 90 ||
            throw(ArgumentError("min_elevation_deg must be in [-90, 90]"))
        max_range_km === nothing || max_range_km > 0 ||
            throw(ArgumentError("max_range_km must be positive when provided"))
        capacity_mbps === nothing || capacity_model === nothing ||
            throw(ArgumentError("provide either capacity_mbps or capacity_model, not both"))
        model = capacity_model === nothing ?
            FixedGSLCapacityModel(capacity_mbps === nothing ? Inf : capacity_mbps) :
            capacity_model
        return new{typeof(model)}(
            Float64(min_elevation_deg),
            max_range_km === nothing ? nothing : Float64(max_range_km),
            model,
        )
    end
end

"""
    gsl_capacity_mbps(model::FixedGSLCapacityModel, elevation_deg::Real)

返回固定容量模型的容量（与仰角无关）。
"""
gsl_capacity_mbps(model::FixedGSLCapacityModel, elevation_deg::Real) =
    model.capacity_mbps

"""
    gsl_capacity_mbps(
        model::ElevationPiecewiseGSLCapacityModel,
        elevation_deg::Real,
    )

分段线性模型：根据仰角返回容量。

# 说明
- 低于截止仰角：返回 `signaling_capacity_mbps`。
- 高于等于饱和仰角：返回 `base_capacity_mbps`。
- 两者之间：线性插值。
"""
# [算法说明]
# 分段线性容量模型
# 将仰角范围分为三段，模拟不同仰角下的带宽变化：
#   - 低于截止仰角：仅保留信令容量（维持最低通信能力）
#   - 截止仰角到饱和仰角：线性插值过渡
#   - 高于饱和仰角：获得完整基准容量
#
# 数学公式：
#   C(elevation) = {
#     C_signal,                           if elevation < cutoff
#     C_signal + (elev - cutoff)/(sat - cutoff) * (C_base - C_signal),  if cutoff <= elevation < sat
#     C_base,                             if elevation >= sat
#   }
function gsl_capacity_mbps(
    model::ElevationPiecewiseGSLCapacityModel,
    elevation_deg::Real,
)
    # 低于截止仰角：仅保留信令容量（保持最低通信能力）
    if elevation_deg < model.cutoff_elevation_deg
        return model.signaling_capacity_mbps
    # 高于等于饱和仰角：获得完整基准容量
    elseif elevation_deg >= model.saturation_elevation_deg
        return model.base_capacity_mbps
    end

    # 两者之间：线性插值，计算仰角在截止和饱和之间的比例
    fraction = (elevation_deg - model.cutoff_elevation_deg) /
        (model.saturation_elevation_deg - model.cutoff_elevation_deg)
    # 信令容量 + 比例 * 容量增量
    return model.signaling_capacity_mbps +
        fraction * (model.base_capacity_mbps - model.signaling_capacity_mbps)
end

"""
    gsl_capacity_mbps(
        model::ElevationExponentialGSLCapacityModel,
        elevation_deg::Real,
    )

指数模型：根据仰角返回容量。

# 说明
- 低于截止仰角：返回 `signaling_capacity_mbps`。
- 否则：按指数增长趋近 `base_capacity_mbps`，并截断不超过基准容量。
"""
# [算法说明]
# 指数容量模型
# 容量按指数方式从信令容量趋近基准容量，更真实地反映仰角增加时
# 信号质量的边际递减效应（高仰角时容量增长趋缓）。
#
# 数学公式：
#   Δelevation = elevation - cutoff_elevation_deg
#   C(elevation) = C_signal + (C_base - C_signal) * (1 - e^(-rate * Δelevation))
#
# 性质：
#   - 当 elevation = cutoff 时，C = C_signal（起始值）
#   - 当 elevation → ∞ 时，C → C_base（渐近值）
#   - rate 参数控制增长速度：rate 越大，容量越快趋近基准值
#   - min 截断确保不会因数值精度问题超过基准容量
function gsl_capacity_mbps(
    model::ElevationExponentialGSLCapacityModel,
    elevation_deg::Real,
)
    # 低于截止仰角：仅保留信令容量
    elevation_deg < model.cutoff_elevation_deg && return model.signaling_capacity_mbps

    # 指数增长模型：容量从信令容量以指数方式趋近基准容量
    # 公式：C = C_signal + (C_base - C_signal) * (1 - e^(-rate * delta_elevation))
    dynamic_capacity = model.signaling_capacity_mbps +
        (model.base_capacity_mbps - model.signaling_capacity_mbps) *
        (1 - exp(-model.growth_rate * (elevation_deg - model.cutoff_elevation_deg)))
    # 确保不超过基准容量
    return min(model.base_capacity_mbps, dynamic_capacity)
end

"""
    gsl_capacity_mbps(config::GSLPhysicalLinkConfig, elevation_deg::Real)

根据配置中的容量模型返回对应仰角下的容量。
"""
gsl_capacity_mbps(config::GSLPhysicalLinkConfig, elevation_deg::Real) =
    gsl_capacity_mbps(config.capacity_model, elevation_deg)

"""
    ISLPhysicalLinkSample{T<:Real}

单个时间片上单条 ISL 的物理链路样本。

# 字段
- `link_id::Int`: 拓扑链路 ID。
- `time_index::Int`: 时间片索引。
- `elapsed_s::Int`: 自 epoch 起的秒数。
- `endpoint_a_id::Int`: 端点 A 全局卫星 ID。
- `endpoint_b_id::Int`: 端点 B 全局卫星 ID。
- `distance_km::T`: 两端点距离（km）。
- `propagation_delay_s::T`: 传播时延（秒）。
- `capacity_mbps::T`: 当前可用容量（Mbps），不可用时为 0。
- `state::AbstractLinkState`: 链路可用状态。
- `line_of_sight::Bool`: 是否无地球遮挡。
"""
struct ISLPhysicalLinkSample{T<:Real}
    link_id::Int
    time_index::Int
    elapsed_s::Int
    endpoint_a_id::Int
    endpoint_b_id::Int
    distance_km::T
    propagation_delay_s::T
    capacity_mbps::T
    state::AbstractLinkState
    line_of_sight::Bool

    function ISLPhysicalLinkSample{T}(;
        link_id::Int,
        time_index::Int,
        elapsed_s::Int,
        endpoint_a_id::Int,
        endpoint_b_id::Int,
        distance_km::Real,
        propagation_delay_s::Real,
        capacity_mbps::Real,
        state::AbstractLinkState,
        line_of_sight::Bool,
    ) where {T<:Real}
        link_id > 0 || throw(ArgumentError("link_id must be positive"))
        time_index > 0 || throw(ArgumentError("time_index must be positive"))
        elapsed_s >= 0 || throw(ArgumentError("elapsed_s must be non-negative"))
        endpoint_a_id > 0 || throw(ArgumentError("endpoint_a_id must be positive"))
        endpoint_b_id > 0 || throw(ArgumentError("endpoint_b_id must be positive"))
        endpoint_a_id != endpoint_b_id || throw(ArgumentError("link endpoints must differ"))
        distance_km >= 0 || throw(ArgumentError("distance_km must be non-negative"))
        propagation_delay_s >= 0 ||
            throw(ArgumentError("propagation_delay_s must be non-negative"))
        capacity_mbps >= 0 || throw(ArgumentError("capacity_mbps must be non-negative"))
        return new{T}(
            link_id,
            time_index,
            elapsed_s,
            endpoint_a_id,
            endpoint_b_id,
            T(distance_km),
            T(propagation_delay_s),
            T(capacity_mbps),
            state,
            line_of_sight,
        )
    end

    function ISLPhysicalLinkSample(;
        link_id::Int,
        time_index::Int,
        elapsed_s::Int,
        endpoint_a_id::Int,
        endpoint_b_id::Int,
        distance_km::Real,
        propagation_delay_s::Real,
        capacity_mbps::Real,
        state::AbstractLinkState,
        line_of_sight::Bool,
    )
        T = promote_type(typeof(distance_km), typeof(propagation_delay_s), typeof(capacity_mbps))
        return ISLPhysicalLinkSample{T}(;
            link_id,
            time_index,
            elapsed_s,
            endpoint_a_id,
            endpoint_b_id,
            distance_km,
            propagation_delay_s,
            capacity_mbps,
            state,
            line_of_sight,
        )
    end
end

"""
    GSLPhysicalLinkSample{T<:Real}

单个时间片上一个地面站到一颗卫星的 GSL 物理链路样本。

# 字段
- `ground_id::Int`: 地面端 ID。
- `satellite_id::Int`: 卫星全局 ID。
- `time_index::Int`: 时间片索引。
- `elapsed_s::Int`: 自 epoch 起的秒数。
- `distance_km::T`: 地面站到卫星距离（km）。
- `propagation_delay_s::T`: 传播时延（秒）。
- `elevation_deg::T`: 地面站处卫星仰角（度）。
- `capacity_mbps::T`: 当前可用容量（Mbps），不可用时为 0。
- `state::AbstractLinkState`: 链路可用状态。
"""
struct GSLPhysicalLinkSample{T<:Real}
    ground_id::Int
    satellite_id::Int
    time_index::Int
    elapsed_s::Int
    distance_km::T
    propagation_delay_s::T
    elevation_deg::T
    capacity_mbps::T
    state::AbstractLinkState

    function GSLPhysicalLinkSample{T}(;
        ground_id::Int,
        satellite_id::Int,
        time_index::Int,
        elapsed_s::Int,
        distance_km::Real,
        propagation_delay_s::Real,
        elevation_deg::Real,
        capacity_mbps::Real,
        state::AbstractLinkState,
    ) where {T<:Real}
        ground_id > 0 || throw(ArgumentError("ground_id must be positive"))
        satellite_id > 0 || throw(ArgumentError("satellite_id must be positive"))
        time_index > 0 || throw(ArgumentError("time_index must be positive"))
        elapsed_s >= 0 || throw(ArgumentError("elapsed_s must be non-negative"))
        distance_km >= 0 || throw(ArgumentError("distance_km must be non-negative"))
        propagation_delay_s >= 0 ||
            throw(ArgumentError("propagation_delay_s must be non-negative"))
        -90 <= elevation_deg <= 90 || throw(ArgumentError("elevation_deg must be in [-90, 90]"))
        capacity_mbps >= 0 || throw(ArgumentError("capacity_mbps must be non-negative"))
        return new{T}(
            ground_id,
            satellite_id,
            time_index,
            elapsed_s,
            T(distance_km),
            T(propagation_delay_s),
            T(elevation_deg),
            T(capacity_mbps),
            state,
        )
    end

    function GSLPhysicalLinkSample(;
        ground_id::Int,
        satellite_id::Int,
        time_index::Int,
        elapsed_s::Int,
        distance_km::Real,
        propagation_delay_s::Real,
        elevation_deg::Real,
        capacity_mbps::Real,
        state::AbstractLinkState,
    )
        T = promote_type(
            typeof(distance_km),
            typeof(propagation_delay_s),
            typeof(elevation_deg),
            typeof(capacity_mbps),
        )
        return GSLPhysicalLinkSample{T}(;
            ground_id,
            satellite_id,
            time_index,
            elapsed_s,
            distance_km,
            propagation_delay_s,
            elevation_deg,
            capacity_mbps,
            state,
        )
    end
end

"""
    ISLPhysicalLinkSeries

某条 ISL 拓扑在所有时间片上的物理链路样本序列。

# 字段
- `topology::ConstellationTopology`: 对应的静态候选拓扑。
- `time_grid::SimulationTimeGrid`: 时间网格。
- `samples_by_time::Vector{<:Vector{<:ISLPhysicalLinkSample}}`: 每个时间片上所有链路的样本。
"""
struct ISLPhysicalLinkSeries
    topology::ConstellationTopology
    time_grid::SimulationTimeGrid
    samples_by_time::Vector{<:Vector{<:ISLPhysicalLinkSample}}

    function ISLPhysicalLinkSeries(
        topology::ConstellationTopology,
        time_grid::SimulationTimeGrid,
        samples_by_time::Vector{<:Vector{<:ISLPhysicalLinkSample}},
    )
        length(samples_by_time) == time_count(time_grid) ||
            throw(ArgumentError("samples_by_time must match the time grid length"))
        for (time_index, samples) in pairs(samples_by_time)
            length(samples) == link_count(topology) ||
                throw(ArgumentError("each time slice must contain one sample per topology link"))
            for (link_index, sample) in pairs(samples)
                sample.time_index == time_index ||
                    throw(ArgumentError("sample time_index must match time slice order"))
                sample.link_id == link_index ||
                    throw(ArgumentError("sample link_id must match topology link order"))
            end
        end
        return new(topology, time_grid, samples_by_time)
    end
end

"""
    GSLPhysicalLinkSeries

单个地面站在所有时间片上对所有卫星的 GSL 物理链路样本序列。

# 字段
- `ground_id::Int`: 地面端 ID。
- `time_grid::SimulationTimeGrid`: 时间网格。
- `samples_by_time::Vector{<:Vector{<:GSLPhysicalLinkSample}}`: 每个时间片上对所有卫星的样本。
"""
struct GSLPhysicalLinkSeries
    ground_id::Int
    time_grid::SimulationTimeGrid
    samples_by_time::Vector{<:Vector{<:GSLPhysicalLinkSample}}

    function GSLPhysicalLinkSeries(
        ground_id::Int,
        time_grid::SimulationTimeGrid,
        samples_by_time::Vector{<:Vector{<:GSLPhysicalLinkSample}},
    )
        ground_id > 0 || throw(ArgumentError("ground_id must be positive"))
        length(samples_by_time) == time_count(time_grid) ||
            throw(ArgumentError("samples_by_time must match the time grid length"))
        for (time_index, samples) in pairs(samples_by_time)
            for sample in samples
                sample.ground_id == ground_id ||
                    throw(ArgumentError("all GSL samples must belong to ground_id"))
                sample.time_index == time_index ||
                    throw(ArgumentError("sample time_index must match time slice order"))
            end
        end
        return new(ground_id, time_grid, samples_by_time)
    end
end

"""
    link_samples_at(series::ISLPhysicalLinkSeries, time_index::Int)::Vector{ISLPhysicalLinkSample}

返回指定时间片上的所有 ISL 样本。
"""
link_samples_at(series::ISLPhysicalLinkSeries, time_index::Int)::Vector{ISLPhysicalLinkSample} =
    series.samples_by_time[time_index]

"""
    gsl_samples_at(series::GSLPhysicalLinkSeries, time_index::Int)::Vector{GSLPhysicalLinkSample}

返回指定时间片上的所有 GSL 样本。
"""
gsl_samples_at(series::GSLPhysicalLinkSeries, time_index::Int)::Vector{GSLPhysicalLinkSample} =
    series.samples_by_time[time_index]

"""
    available_link_samples(series::ISLPhysicalLinkSeries, time_index::Int)::Vector{ISLPhysicalLinkSample}

返回指定时间片上状态为可用的 ISL 样本。
"""
function available_link_samples(series::ISLPhysicalLinkSeries, time_index::Int)::Vector{ISLPhysicalLinkSample}
    return [
        sample for sample in link_samples_at(series, time_index)
        if sample.state isa LinkAvailable
    ]
end

"""
    available_gsl_samples(series::GSLPhysicalLinkSeries, time_index::Int)::Vector{GSLPhysicalLinkSample}

返回指定时间片上状态为可用的 GSL 样本。
"""
function available_gsl_samples(series::GSLPhysicalLinkSeries, time_index::Int)::Vector{GSLPhysicalLinkSample}
    return [
        sample for sample in gsl_samples_at(series, time_index)
        if sample.state isa LinkAvailable
    ]
end

"""
    position_vector_km(sample::EphemerisSample)::Vector{Float64}

从星历样本中提取笛卡尔位置向量（km）。

# 说明
- 要求星历样本包含 `cartesian` 字段，否则报错。
"""
function position_vector_km(sample::EphemerisSample)::Vector{Float64}
    sample.cartesian !== nothing ||
        throw(ArgumentError("ISL physical evaluation requires Cartesian ephemeris samples"))
    return collect(sample.cartesian.position_km)
end

"""
    distance_km(a::CartesianState, b::CartesianState)

计算两个笛卡尔状态之间的距离（km）。
"""
distance_km(a::CartesianState, b::CartesianState) =
    norm(collect(a.position_km) - collect(b.position_km))

"""
    distance_km(a::EphemerisSample, b::EphemerisSample)

计算两个星历样本位置之间的距离（km）。
"""
distance_km(a::EphemerisSample, b::EphemerisSample) =
    norm(position_vector_km(a) - position_vector_km(b))

"""
    propagation_delay_s(distance_km::Real)

根据距离计算光传播时延（秒）。
"""
propagation_delay_s(distance_km::Real) = distance_km / SPEED_OF_LIGHT_KM_S

"""
    geodetic_to_ecef_km(position::GeodeticPosition)::Vector{Float64}

将大地坐标（纬度、经度、海拔）转换为 ECEF 笛卡尔坐标（km）。

# 依赖
- 调用 `SatelliteToolbox.geodetic_to_ecef` 进行坐标转换。
"""
function geodetic_to_ecef_km(position::GeodeticPosition)::Vector{Float64}
    ecef_m = SatelliteToolbox.geodetic_to_ecef(
        deg2rad(position.latitude_deg),
        deg2rad(position.longitude_deg),
        position.altitude_km * 1000,
    )
    return collect(Float64(value / 1000) for value in ecef_m)
end

"""
    elevation_deg(
        ground_position::GeodeticPosition,
        satellite_ecef_km::AbstractVector{<:Real},
    )::Float64

计算地面站处卫星的仰角（度）。

# 参数
- `ground_position`: 地面站大地坐标。
- `satellite_ecef_km`: 卫星 ECEF 位置（km）。

# 返回值
- 仰角（度），范围 [-90, 90]。

# 依赖
- 调用 `SatelliteToolbox.ecef_to_ned` 将卫星位置转换到地面站 NED 局部坐标系，
  再通过天底角计算仰角。
"""
# [算法说明]
# 仰角（Elevation Angle）计算算法
# 仰角是地面站观测卫星时，卫星方向与地平面的夹角，范围 [-90°, 90°]。
# 仰角越大（越接近天顶），链路质量越好，受大气衰减和遮挡影响越小。
#
# 算法步骤：
#   1. 将卫星 ECEF 坐标转换到地面站局部 NED（北-东-地）坐标系
#      NED 系原点在地面站位置，x 轴指向北，y 轴指向东，z 轴指向地心
#   2. 计算天底角（nadir angle）：卫星方向与天顶方向（-z）的夹角
#      nadir_angle = arccos(-NED_z / |NED|)
#   3. 仰角 = 90° - 天底角
#
# 几何关系：
#   天顶方向对应 NED 的 -z 方向，地平面垂直于天顶方向。
#   当卫星在天顶正上方时，nadir_angle = 0°，仰角 = 90°。
#   当卫星在地平线上时，nadir_angle = 90°，仰角 = 0°。
function elevation_deg(ground_position::GeodeticPosition, satellite_ecef_km::AbstractVector{<:Real})::Float64
    satellite = Float64.(satellite_ecef_km)
    length(satellite) == 3 || throw(ArgumentError("satellite_ecef_km must have 3 components"))
    # 将卫星 ECEF 坐标转换到地面站 NED（北-东-地）局部坐标系
    satellite_ned_m = SatelliteToolbox.ecef_to_ned(
        satellite .* 1000,  # 转换为米
        deg2rad(ground_position.latitude_deg),
        deg2rad(ground_position.longitude_deg),
        ground_position.altitude_km * 1000;  # 转换为米
        translate = true,  # 平移坐标原点到地面站位置
    )
    range_norm = norm(satellite_ned_m)
    # 如果卫星就在地面站位置，仰角为 90 度（天顶）
    range_norm > 0 || return 90.0
    # 天底角：卫星方向与局部天顶（NED 下 -z 方向）的夹角
    # NED 系中，天顶指向 -z 方向（向上），地球表面指向 +z 方向（向下）
    # satellite_ned_m[3] 是 z 分量，-satellite_ned_m[3] 是向天顶方向的分量
    # clamp 确保 acos 的参数在 [-1, 1] 范围内，避免数值误差导致 NaN
    nadir_angle = acos(clamp(-satellite_ned_m[3] / range_norm, -1.0, 1.0))
    # 仰角 = 90° - 天底角
    return rad2deg(π / 2 - nadir_angle)
end

"""
    line_of_sight_clear(
        position_a_km::AbstractVector{<:Real},
        position_b_km::AbstractVector{<:Real};
        earth_radius_km::Real = WGS84_EQUATORIAL_RADIUS_KM,
    )::Bool

判断两点之间的视线是否被地球遮挡。

# 参数
- `position_a_km`, `position_b_km`: 两点 ECEF 坐标（km）。
- `earth_radius_km`: 地球半径（km）。

# 返回值
- `true` 表示视线不被地球遮挡。

# 说明
- 通过计算线段到地心最近距离来判断；若最近点在线段内部且低于地球半径，则遮挡。
"""
# [算法说明]
# 视距（Line of Sight, LOS）判断算法
# 核心思想：将地球简化为球体，检查卫星A到卫星B的连线段是否与地球球体相交。
# 数学原理：
#   设线段起点为 a，终点为 b，地心为原点 O。
#   地心到线段的最近距离可以通过向量投影求得：
#     1. 线段方向向量 s = b - a
#     2. 从 a 指向地心的向量为 -a
#     3. 将 -a 投影到 s 上得到参数 t = (-a · s) / (s · s)
#     4. 截断 t 到 [0, 1]，得到最近点在段上的位置
#     5. 最近点 = a + t * s
#     6. 若 |最近点| > R_earth，则视线不被遮挡
#
# 该算法的时间复杂度为 O(1)，适合在每个时间步对大量链路进行批量评估。
function line_of_sight_clear(
    position_a_km::AbstractVector{<:Real},
    position_b_km::AbstractVector{<:Real};
    earth_radius_km::Real = WGS84_EQUATORIAL_RADIUS_KM,
)::Bool
    a = Float64.(position_a_km)
    b = Float64.(position_b_km)
    length(a) == 3 || throw(ArgumentError("position_a_km must have 3 components"))
    length(b) == 3 || throw(ArgumentError("position_b_km must have 3 components"))

    segment = b - a  # 从 a 到 b 的向量
    segment_norm_sq = dot(segment, segment)  # 线段长度的平方
    # 如果两点重合，直接检查点 a 是否在地球表面外
    segment_norm_sq > 0 || return norm(a) > earth_radius_km

    # 计算 a 到线段上最近点的参数（投影到线段上并截断到 [0,1]）
    # 原理：从原点（地心）到线段的垂足位置，使用向量投影公式
    # clamp 保证参数在 [0,1] 范围内，确保最近点在线段上而非延长线上
    closest_fraction = clamp(-dot(a, segment) / segment_norm_sq, 0.0, 1.0)
    # 最近点坐标
    closest = a + closest_fraction * segment
    # 如果最近点到地心的距离大于地球半径，则视线不被遮挡
    return norm(closest) > earth_radius_km
end

"""
    gsl_is_available(
        distance_km::Float64,
        elevation_deg::Float64,
        config::GSLPhysicalLinkConfig,
    )::Bool

基于距离与仰角判断 GSL 是否可用（简化版本）。
"""
function gsl_is_available(
    distance_km::Float64,
    elevation_deg::Float64,
    config::GSLPhysicalLinkConfig,
)::Bool
    # 检查是否在最大距离范围内（未配置则不限制）
    in_range = config.max_range_km === nothing || distance_km <= config.max_range_km
    # 检查仰角是否高于最小仰角（避免地球遮挡和大气衰减）
    above_mask = elevation_deg >= config.min_elevation_deg
    return in_range && above_mask
end

"""
    gsl_is_available(
        distance_km::Float64,
        ground_position::GeodeticPosition,
        satellite_ecef_km::AbstractVector{<:Real},
        config::GSLPhysicalLinkConfig,
    )::Bool

基于 SatelliteAnalysis 的可见性函数判断 GSL 是否可用。

# 参数
- `distance_km`: 地面站到卫星距离（km）。
- `ground_position`: 地面站大地坐标。
- `satellite_ecef_km`: 卫星 ECEF 坐标（km）。
- `config`: GSL 物理链路配置。

# 依赖
- 调用 `SatelliteAnalysis.is_ground_facility_visible` 判断几何可见性。
"""
function gsl_is_available(
    distance_km::Float64,
    ground_position::GeodeticPosition,
    satellite_ecef_km::AbstractVector{<:Real},
    config::GSLPhysicalLinkConfig,
)::Bool
    # 检查是否在最大距离范围内（未配置则不限制）
    in_range = config.max_range_km === nothing || distance_km <= config.max_range_km
    # 使用 SatelliteAnalysis 进行精确的几何可见性判断
    # 考虑地球曲率、最小仰角约束等因素
    visible = SatelliteAnalysis.is_ground_facility_visible(
        Float64.(satellite_ecef_km) .* 1000,  # 转换为米
        deg2rad(ground_position.latitude_deg),
        deg2rad(ground_position.longitude_deg),
        ground_position.altitude_km * 1000,  # 转换为米
        deg2rad(config.min_elevation_deg),
    )
    return in_range && visible
end

"""
    link_is_available(
        distance_km::Float64,
        line_of_sight::Bool,
        config::ISLPhysicalLinkConfig,
    )::Bool

判断 ISL 是否满足距离与视距约束。
"""
function link_is_available(
    distance_km::Float64,
    line_of_sight::Bool,
    config::ISLPhysicalLinkConfig,
)::Bool
    # 检查是否在最大距离范围内（未配置则不限制）
    in_range = config.max_range_km === nothing || distance_km <= config.max_range_km
    # 检查视距约束：如果配置要求视距，则必须有 LOS；否则忽略 LOS 检查
    visible = !config.require_line_of_sight || line_of_sight
    return in_range && visible
end

"""
    evaluate_gsl_sample(
        ground_id::Int,
        ground_position::GeodeticPosition,
        satellite_sample::EphemerisSample,
        config::GSLPhysicalLinkConfig,
    )::GSLPhysicalLinkSample

评估单个地面站到单个卫星在某一时间片的 GSL 物理链路样本。

# 参数
- `ground_id`: 地面端 ID。
- `ground_position`: 地面站大地坐标。
- `satellite_sample`: 卫星星历样本。
- `config`: GSL 物理链路配置。

# 返回值
- 构造好的 `GSLPhysicalLinkSample`。
"""
function evaluate_gsl_sample(
    ground_id::Int,
    ground_position::GeodeticPosition,
    satellite_sample::EphemerisSample,
    config::GSLPhysicalLinkConfig,
)::GSLPhysicalLinkSample
    # 验证星历样本包含笛卡尔坐标
    satellite_sample.cartesian !== nothing ||
        throw(ArgumentError("GSL physical evaluation requires Cartesian satellite ephemeris"))
    # 验证坐标参考系为 ECEF 或 ITRF（地心地固坐标系）
    satellite_sample.cartesian.frame == ECEF || satellite_sample.cartesian.frame == ITRF ||
        throw(ArgumentError("GSL physical evaluation requires ECEF or ITRF satellite coordinates"))

    # 提取卫星位置向量
    satellite_position = position_vector_km(satellite_sample)
    # 将地面站大地坐标转换为 ECEF 坐标
    ground_position_ecef = geodetic_to_ecef_km(ground_position)
    # 计算距离（欧氏距离）
    distance = norm(satellite_position - ground_position_ecef)
    # 计算地面站处卫星仰角
    elevation = elevation_deg(ground_position, satellite_position)
    # 判断链路是否可用（距离范围 + 几何可见性）
    available = gsl_is_available(distance, ground_position, satellite_position, config)

    return GSLPhysicalLinkSample(
        ground_id = ground_id,
        satellite_id = satellite_sample.satellite_id,
        time_index = satellite_sample.time_index,
        elapsed_s = satellite_sample.elapsed_s,
        distance_km = distance,
        propagation_delay_s = propagation_delay_s(distance),  # 光传播时延 = 距离 / 光速
        elevation_deg = elevation,
        capacity_mbps = available ? gsl_capacity_mbps(config, elevation) : 0.0,  # 根据仰角计算容量
        state = available ? LinkAvailable() : LinkUnavailable(),
    )
end

"""
    evaluate_gsl_physical_links(
        ground_id::Int,
        ground_position::GeodeticPosition,
        ephemeris::ConstellationEphemeris;
        config::GSLPhysicalLinkConfig = GSLPhysicalLinkConfig(),
    )::GSLPhysicalLinkSeries

对指定地面站评估其在所有时间片上对所有卫星的 GSL 物理链路。

# 参数
- `ground_id`: 地面端 ID。
- `ground_position`: 地面站大地坐标。
- `ephemeris`: 星座星历。
- `config`: GSL 物理链路配置。

# 返回值
- `GSLPhysicalLinkSeries`。
"""
function evaluate_gsl_physical_links(
    ground_id::Int,
    ground_position::GeodeticPosition,
    ephemeris::ConstellationEphemeris;
    config::GSLPhysicalLinkConfig = GSLPhysicalLinkConfig(),
)::GSLPhysicalLinkSeries
    samples_by_time = Vector{Vector{GSLPhysicalLinkSample}}()
    # 遍历每个时间片，评估该时间片上对所有卫星的 GSL 链路
    for time_index in 1:time_count(ephemeris.time_grid)
        push!(
            samples_by_time,
            [
                evaluate_gsl_sample(ground_id, ground_position, satellite_ephemeris[time_index], config)
                for satellite_ephemeris in ephemeris.satellites  # 对每颗卫星评估一个样本
            ],
        )
    end
    return GSLPhysicalLinkSeries(ground_id, ephemeris.time_grid, samples_by_time)
end

"""
    evaluate_gsl_physical_links(
        ground_station::GroundStation,
        ephemeris::ConstellationEphemeris;
        config::GSLPhysicalLinkConfig = GSLPhysicalLinkConfig(),
    )::GSLPhysicalLinkSeries

基于 `GroundStation` 对象评估 GSL 物理链路。
"""
function evaluate_gsl_physical_links(
    ground_station::GroundStation,
    ephemeris::ConstellationEphemeris;
    config::GSLPhysicalLinkConfig = GSLPhysicalLinkConfig(),
)::GSLPhysicalLinkSeries
    return evaluate_gsl_physical_links(
        ground_station.id,
        ground_station.position,
        ephemeris;
        config = config,
    )
end

"""
    evaluate_gsl_physical_links(
        user_terminal::UserTerminal,
        ephemeris::ConstellationEphemeris;
        config::GSLPhysicalLinkConfig = GSLPhysicalLinkConfig(),
    )::GSLPhysicalLinkSeries

基于 `UserTerminal` 对象评估 GSL 物理链路。
"""
function evaluate_gsl_physical_links(
    user_terminal::UserTerminal,
    ephemeris::ConstellationEphemeris;
    config::GSLPhysicalLinkConfig = GSLPhysicalLinkConfig(),
)::GSLPhysicalLinkSeries
    return evaluate_gsl_physical_links(
        user_terminal.id,
        user_terminal.position,
        ephemeris;
        config = config,
    )
end

"""
    evaluate_isl_link_sample(
        link::SatelliteLink,
        ephemeris::ConstellationEphemeris,
        time_index::Int,
        config::ISLPhysicalLinkConfig,
    )::ISLPhysicalLinkSample

评估单条 ISL 在某一时间片的物理链路样本。

# 参数
- `link`: 静态拓扑中的链路。
- `ephemeris`: 星座星历。
- `time_index`: 时间片索引。
- `config`: ISL 物理链路配置。

# 返回值
- 构造好的 `ISLPhysicalLinkSample`。
"""
function evaluate_isl_link_sample(
    link::SatelliteLink,
    ephemeris::ConstellationEphemeris,
    time_index::Int,
    config::ISLPhysicalLinkConfig,
)::ISLPhysicalLinkSample
    # 验证链路类型为星间链路（不支持地面-卫星链路）
    link.link_type isa InterSatelliteLink ||
        throw(ArgumentError("ISL physical evaluation only supports InterSatelliteLink"))

    # 获取两端点卫星在同一时间片的星历样本
    sample_a = ephemeris[endpoint_global_id(link.endpoint_a)][time_index]
    sample_b = ephemeris[endpoint_global_id(link.endpoint_b)][time_index]
    elapsed_s = sample_a.elapsed_s
    # 验证两个星历样本的时间戳一致
    sample_b.elapsed_s == elapsed_s ||
        throw(ArgumentError("link endpoint ephemeris samples must share elapsed_s"))

    # 提取两端点位置向量
    position_a = position_vector_km(sample_a)
    position_b = position_vector_km(sample_b)
    # 计算两端点间的欧氏距离
    distance = norm(position_b - position_a)
    # 判断视线是否被地球遮挡
    line_of_sight = line_of_sight_clear(
        position_a,
        position_b;
        earth_radius_km = config.earth_radius_km,
    )
    # 根据距离和视距约束判断链路是否可用
    available = link_is_available(distance, line_of_sight, config)

    return ISLPhysicalLinkSample(
        link_id = link.id,
        time_index = time_index,
        elapsed_s = elapsed_s,
        endpoint_a_id = endpoint_global_id(link.endpoint_a),
        endpoint_b_id = endpoint_global_id(link.endpoint_b),
        distance_km = distance,
        propagation_delay_s = propagation_delay_s(distance),  # 光传播时延 = 距离 / 光速
        capacity_mbps = available ? config.capacity_mbps : 0.0,  # 可用时返回配置容量，否则为 0
        state = available ? LinkAvailable() : LinkUnavailable(),
        line_of_sight = line_of_sight,
    )
end

"""
    evaluate_isl_physical_links(
        topology::ConstellationTopology,
        ephemeris::ConstellationEphemeris;
        config::ISLPhysicalLinkConfig = ISLPhysicalLinkConfig(),
    )::ISLPhysicalLinkSeries

对指定拓扑在所有时间片上评估所有 ISL 的物理链路。

# 参数
- `topology`: 静态 ISL 候选拓扑。
- `ephemeris`: 星座星历。
- `config`: ISL 物理链路配置。

# 返回值
- `ISLPhysicalLinkSeries`。
"""
function evaluate_isl_physical_links(
    topology::ConstellationTopology,
    ephemeris::ConstellationEphemeris;
    config::ISLPhysicalLinkConfig = ISLPhysicalLinkConfig(),
)::ISLPhysicalLinkSeries
    # 验证拓扑和星历属于同一星座
    topology.constellation_name == ephemeris.constellation_name ||
        throw(ArgumentError("topology and ephemeris must belong to the same constellation"))

    samples_by_time = Vector{Vector{ISLPhysicalLinkSample}}()
    # 遍历每个时间片，评估该时间片上所有拓扑链路的物理状态
    for time_index in 1:time_count(ephemeris.time_grid)
        push!(
            samples_by_time,
            [
                evaluate_isl_link_sample(link, ephemeris, time_index, config)
                for link in topology_links(topology)  # 对拓扑中的每条链路评估一个样本
            ],
        )
    end

    return ISLPhysicalLinkSeries(topology, ephemeris.time_grid, samples_by_time)
end

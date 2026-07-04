"""
    time

仿真时间与环境模块。

本文件定义了贯穿整个仿真流水线的时间网格、epoch 以及环境模型：

主要数据结构：
- `TimeSystem`：时间系统枚举（UTC/TAI/TT/UT1）
- `EarthRotationEnvironment`：地球自转环境参数
- `SolarEnvironment`：太阳辐射环境参数
- `AtmosphereEnvironment`：大气阻力环境参数
- `FrameEnvironment`：参考系环境参数
- `EpochEnvironment`：epoch 时刻的完整环境配置
- `SimulationEpoch`：仿真的起始时刻及其环境配置
- `SimulationTimeGrid`：仿真时间网格，定义总时长、步长与每个时间片的偏移量

时间网格是跨层对齐的关键：轨道传播器、网络链路评估、流量/能耗计算、
轨道事件流（OEF）都依赖 `SimulationTimeGrid` 保证时间索引一致。

依赖：
- Dates：Julia 标准库，用于 DateTime 与儒略日相关计算
"""

using Dates

export SimulationTimeGrid, SimulationEpoch
export time_count

"""
    TimeSystem

仿真使用的时间系统枚举。

# 时间系统类型
- `TimeUTC`：协调世界时（Coordinated Universal Time），项目默认使用
- `TimeTAI`：国际原子时（International Atomic Time）
- `TimeTT`：地球时（Terrestrial Time）
- `TimeUT1`：UT1，考虑地球自转不均匀性的时间系统

# 说明
不同的时间系统之间存在微小的时间偏差，选择哪种时间系统取决于具体的应用场景和精度要求。
"""
@enum TimeSystem begin
    TimeUTC   # 协调世界时
    TimeTAI   # 国际原子时
    TimeTT    # 地球时
    TimeUT1   # UT1
end

"""
    EarthRotationEnvironmentModel

地球自转环境模型枚举。

# 模型类型
- `EarthRotationUniform`：均匀自转模型，使用固定角速度（7.2921150e-5 rad/s）
- `EarthRotationIERS`：基于 IERS（国际地球自转和参考系服务）地球定向参数的模型

# 说明
- 均匀模型适用于大多数仿真场景，计算效率高
- IERS 模型提供更高精度的地球定向参数，适用于精密轨道计算
"""
@enum EarthRotationEnvironmentModel begin
    EarthRotationUniform
    EarthRotationIERS
end

"""
    SolarEnvironmentModel

太阳辐射环境模型枚举。

# 模型类型
- `SolarEnvironmentDisabled`：不建模太阳辐射
- `SolarEnvironmentAnalytic`：解析太阳辐射模型，使用解析公式计算太阳位置和辐射
- `SolarEnvironmentEphemeris`：基于星历的太阳辐射模型，使用精确的太阳位置星历数据

# 说明
选择哪种模型取决于仿真精度要求和计算资源。
"""
@enum SolarEnvironmentModel begin
    SolarEnvironmentDisabled
    SolarEnvironmentAnalytic
    SolarEnvironmentEphemeris
end

"""
    AtmosphereEnvironmentModel

大气阻力环境模型枚举。

# 模型类型
- `AtmosphereEnvironmentDisabled`：不建模大气阻力（适用于轨道高度很高的卫星）
- `AtmosphereEnvironmentBStarOnly`：仅使用 TLE 中的 B* 阻力系数
- `AtmosphereEnvironmentSpaceWeather`：基于空间天气数据（如 F10.7 指数）的模型

# 说明
大气阻力是低地球轨道卫星的主要摄动力，选择合适的模型对轨道精度很重要。
"""
@enum AtmosphereEnvironmentModel begin
    AtmosphereEnvironmentDisabled
    AtmosphereEnvironmentBStarOnly
    AtmosphereEnvironmentSpaceWeather
end

"""
    FrameEnvironmentModel

参考系环境模型枚举。

# 模型类型
- `FrameEnvironmentSimpleTEME`：简化 TEME（真赤道平春分点）参考系处理
- `FrameEnvironmentIERS`：基于 IERS 参数的参考系处理

# 说明
TEME 是 TLE 轨道数据使用的参考系，简化处理适用于大多数场景。
IERS 处理提供更精确的参考系转换参数。
"""
@enum FrameEnvironmentModel begin
    FrameEnvironmentSimpleTEME
    FrameEnvironmentIERS
end

"""
    EarthRotationEnvironment

描述 epoch 时刻的地球自转环境。

地球自转参数用于计算地球固定坐标系与惯性坐标系之间的转换。

# 字段
- `model::EarthRotationEnvironmentModel`：自转模型类型
- `reference_angle_rad::Float64`：参考初始角度（弧度），表示 epoch 时刻的格林尼治恒星时
- `reference_rate_rad_s::Float64`：地球自转角速度（弧度/秒），默认值为 7.2921150e-5

# 构造参数
- `model::EarthRotationEnvironmentModel`：自转模型，默认为 EarthRotationUniform
- `reference_angle_rad::Real`：参考角度（弧度），默认为 0
- `reference_rate_rad_s::Real`：自转角速度，默认为 7.2921150e-5

# 异常
- `ArgumentError`：当 reference_rate_rad_s 不是正数时抛出

# 说明
地球自转角速度的精确值约为 7.2921150e-5 rad/s，对应 23小时56分4.0905秒自转一周。
"""
struct EarthRotationEnvironment
    model::EarthRotationEnvironmentModel
    reference_angle_rad::Float64
    reference_rate_rad_s::Float64

    function EarthRotationEnvironment(;
        model::EarthRotationEnvironmentModel = EarthRotationUniform,
        reference_angle_rad::Real = 0,
        reference_rate_rad_s::Real = OMEGA_EARTH,
    )
        # 验证自转角速度为正数
        reference_rate_rad_s > 0 ||
            throw(ArgumentError("reference_rate_rad_s must be positive"))
        return new(model, Float64(reference_angle_rad), Float64(reference_rate_rad_s))
    end
end

"""
    SolarEnvironment

描述 epoch 时刻的太阳辐射环境。

太阳辐射参数用于计算太阳能发电功率和地影情况。

# 字段
- `model::SolarEnvironmentModel`：太阳辐射模型类型
- `include_eclipse::Bool`：是否在功耗/能源模型中考虑地影
- `solar_constant_w_m2::Float64`：太阳常数（W/m²），默认约 1361

# 构造参数
- `model::SolarEnvironmentModel`：太阳辐射模型，默认为 SolarEnvironmentDisabled
- `include_eclipse::Bool`：是否考虑地影，默认为 false
- `solar_constant_w_m2::Real`：太阳常数，默认为 1361

# 异常
- `ArgumentError`：当 solar_constant_w_m2 不是正数时抛出

# 说明
太阳常数表示地球大气层外单位面积接收的太阳辐射功率，标准值约为 1361 W/m²。
地影是指卫星进入地球阴影区域时无法接收太阳能的情况。
"""
struct SolarEnvironment
    model::SolarEnvironmentModel
    include_eclipse::Bool
    solar_constant_w_m2::Float64

    function SolarEnvironment(;
        model::SolarEnvironmentModel = SolarEnvironmentDisabled,
        include_eclipse::Bool = false,
        solar_constant_w_m2::Real = 1361,
    )
        # 验证太阳常数为正数
        solar_constant_w_m2 > 0 ||
            throw(ArgumentError("solar_constant_w_m2 must be positive"))
        return new(model, include_eclipse, Float64(solar_constant_w_m2))
    end
end

"""
    AtmosphereEnvironment

描述 epoch 时刻的大气阻力环境。

大气参数用于计算大气阻力对卫星轨道的影响。

# 字段
- `model::AtmosphereEnvironmentModel`：大气模型类型
- `f107::Union{Nothing,Float64}`：太阳 10.7 cm 射电通量指数，单位为 10^-22 W/m²/Hz
- `ap::Union{Nothing,Float64}`：地磁活动指数

# 构造参数
- `model::AtmosphereEnvironmentModel`：大气模型，默认为 AtmosphereEnvironmentBStarOnly
- `f107::Union{Nothing,Real}`：太阳 F10.7 指数，默认为 nothing
- `ap::Union{Nothing,Real}`：地磁 ap 指数，默认为 nothing

# 异常
- `ArgumentError`：当 f107 或 ap 为负数时抛出

# 说明
- F10.7 指数反映太阳活动水平，影响高层大气密度
- ap 指数反映地磁活动水平，也影响大气密度
- 两者都是空间天气预报的重要参数
"""
struct AtmosphereEnvironment
    model::AtmosphereEnvironmentModel
    f107::Union{Nothing,Float64}
    ap::Union{Nothing,Float64}

    function AtmosphereEnvironment(;
        model::AtmosphereEnvironmentModel = AtmosphereEnvironmentBStarOnly,
        f107::Union{Nothing,Real} = nothing,
        ap::Union{Nothing,Real} = nothing,
    )
        # 验证 F10.7 指数（如果提供）
        f107 === nothing || f107 >= 0 || throw(ArgumentError("f107 must be non-negative"))
        # 验证 ap 指数（如果提供）
        ap === nothing || ap >= 0 || throw(ArgumentError("ap must be non-negative"))
        return new(
            model,
            f107 === nothing ? nothing : Float64(f107),
            ap === nothing ? nothing : Float64(ap),
        )
    end
end

"""
    FrameEnvironment

描述参考系转换所需的环境修正参数。

这些参数用于在不同坐标系之间进行精确转换。

# 字段
- `model::FrameEnvironmentModel`：参考系模型类型
- `ut1_utc_s::Float64`：UT1 与 UTC 的时间差（秒），表示地球自转不规则性
- `polar_motion_x_arcsec::Float64`：极移 x 分量（角秒）
- `polar_motion_y_arcsec::Float64`：极移 y 分量（角秒）

# 构造参数
- `model::FrameEnvironmentModel`：参考系模型，默认为 FrameEnvironmentSimpleTEME
- `ut1_utc_s::Real`：UT1-UTC 时间差，默认为 0
- `polar_motion_x_arcsec::Real`：极移 x 分量，默认为 0
- `polar_motion_y_arcsec::Real`：极移 y 分量，默认为 0

# 说明
- UT1-UTC 的值通常在 ±0.9 秒范围内变化
- 极移是由于地球自转轴相对于地球表面位置的变化引起的
- 这些参数对于精密轨道计算很重要
"""
struct FrameEnvironment
    model::FrameEnvironmentModel
    ut1_utc_s::Float64
    polar_motion_x_arcsec::Float64
    polar_motion_y_arcsec::Float64

    function FrameEnvironment(;
        model::FrameEnvironmentModel = FrameEnvironmentSimpleTEME,
        ut1_utc_s::Real = 0,
        polar_motion_x_arcsec::Real = 0,
        polar_motion_y_arcsec::Real = 0,
    )
        return new(
            model,
            Float64(ut1_utc_s),
            Float64(polar_motion_x_arcsec),
            Float64(polar_motion_y_arcsec),
        )
    end
end

"""
    EpochEnvironment

仿真起始时刻的完整环境配置容器。

将各种环境参数聚合到一个结构中，便于统一管理和传递。

# 字段
- `earth_rotation::EarthRotationEnvironment`：地球自转环境
- `solar::SolarEnvironment`：太阳辐射环境
- `atmosphere::AtmosphereEnvironment`：大气阻力环境
- `frame::FrameEnvironment`：参考系环境参数

# 构造参数
- `earth_rotation::EarthRotationEnvironment`：地球自转环境，默认为默认构造
- `solar::SolarEnvironment`：太阳辐射环境，默认为默认构造
- `atmosphere::AtmosphereEnvironment`：大气环境，默认为默认构造
- `frame::FrameEnvironment`：参考系环境，默认为默认构造
"""
struct EpochEnvironment
    earth_rotation::EarthRotationEnvironment
    solar::SolarEnvironment
    atmosphere::AtmosphereEnvironment
    frame::FrameEnvironment

    function EpochEnvironment(;
        earth_rotation::EarthRotationEnvironment = EarthRotationEnvironment(),
        solar::SolarEnvironment = SolarEnvironment(),
        atmosphere::AtmosphereEnvironment = AtmosphereEnvironment(),
        frame::FrameEnvironment = FrameEnvironment(),
    )
        return new(earth_rotation, solar, atmosphere, frame)
    end
end

"""
    SimulationEpoch

仿真的起始时刻对象。

定义仿真的起始时间、使用的时间系统以及该时刻的环境配置。

# 字段
- `instant::DateTime`：epoch 的真实日历时间
- `system::TimeSystem`：使用的时间系统，默认为 TimeUTC
- `environment::EpochEnvironment`：该 epoch 时刻的物理环境配置

# 构造参数
- `instant::DateTime`：起始时刻的日历时间
- `system::TimeSystem`：时间系统，默认为 TimeUTC
- `environment::EpochEnvironment`：环境配置，默认为默认构造

# 说明
epoch 是所有时间计算的基准点，所有时间索引都相对于这个时刻。
"""
struct SimulationEpoch
    instant::DateTime
    system::TimeSystem
    environment::EpochEnvironment

    function SimulationEpoch(
        instant::DateTime,
        system::TimeSystem = TimeUTC,
        environment::EpochEnvironment = EpochEnvironment(),
    )
        return new(instant, system, environment)
    end
end

"""
    default_simulation_epoch_environment() -> EpochEnvironment

返回默认的 epoch 环境配置（均为各自类型的默认构造参数）。

# 返回值
- `EpochEnvironment`：使用所有默认参数的环境配置
"""
default_simulation_epoch_environment()::EpochEnvironment = EpochEnvironment()

"""
    default_starlink_simulation_epoch() -> SimulationEpoch

返回项目默认的 Starlink 仿真 epoch：2026-01-01 00:00:00 UTC。

# 返回值
- `SimulationEpoch`：2026-01-01 00:00:00 UTC 的 epoch 对象
"""
default_starlink_simulation_epoch()::SimulationEpoch =
    SimulationEpoch(DateTime(2026, 1, 1), TimeUTC, default_simulation_epoch_environment())

"""
    simulation_epoch_year(epoch::SimulationEpoch) -> Int

返回 epoch 年份的后两位（TLE 格式中的年份表示）。

# 参数
- `epoch::SimulationEpoch`：仿真 epoch

# 返回值
- `Int`：年份的后两位（例如 2026 返回 26）

# 说明
TLE（两行轨道数据）格式中使用两位数表示年份（00-99），
这是为了兼容 1957-2056 年的范围。
"""
simulation_epoch_year(epoch::SimulationEpoch)::Int = Dates.year(epoch.instant) % 100

"""
    simulation_epoch_day(epoch::SimulationEpoch) -> Float64

返回 epoch 在当年中的"年积日"（TLE 格式）。

年积日表示从当年 1 月 1 日开始经过的天数，包括小数部分。

# 参数
- `epoch::SimulationEpoch`：仿真 epoch

# 返回值
- `Float64`：年积日，1 月 1 日 0 时对应 1.0

# 算法说明
1. 获取当年 1 月 1 日 0 时的 DateTime
2. 计算当前时刻与 1 月 1 日的差值（毫秒）
3. 将差值转换为天数并加上 1（因为 TLE 格式从 1 开始计数）

# 示例
- 2026-01-01 00:00:00 → 1.0
- 2026-01-01 12:00:00 → 1.5
- 2026-01-02 00:00:00 → 2.0
"""
function simulation_epoch_day(epoch::SimulationEpoch)::Float64
    # 获取当年 1 月 1 日
    start = DateTime(Dates.year(epoch.instant), 1, 1)
    # 计算差值（毫秒转换为天）并加 1
    return Dates.value(epoch.instant - start) / 86_400_000 + 1
end

"""
    SimulationTimeGrid

仿真时间网格。

定义仿真过程中的时间采样点，是整个仿真系统时间同步的基础。

# 字段
- `epoch::SimulationEpoch`：起始 epoch
- `duration_s::Int`：仿真总时长（秒）
- `step_s::Int`：相邻时间片之间的大步步长（秒）
- `offsets_s::Vector{Int}`：每个时间片距离 epoch 的秒数列表

# 构造参数
- `epoch::SimulationEpoch`：起始 epoch
- `duration_s::Int`：仿真总时长（秒）
- `step_s::Int`：时间步长（秒）

# 约束条件
- duration_s 必须非负
- step_s 必须为正数

# 算法说明
构造时生成 `0:step_s:duration_s` 的序列。
如果 duration_s 不是 step_s 的整数倍，则在末尾额外加入 duration_s，
确保终点时刻一定被采样。

# 示例
- `SimulationTimeGrid(epoch, 10, 3)` → offsets_s = [0, 3, 6, 9, 10]
- `SimulationTimeGrid(epoch, 12, 3)` → offsets_s = [0, 3, 6, 9, 12]

# 异常
- `ArgumentError`：当参数不符合约束条件时抛出

# 说明
所有依赖时间网格的模块（轨道传播、链路评估、流量计算、OEF 生成）都应共享同一个
`SimulationTimeGrid` 对象，以保证时间索引一致。

时间索引与偏移量的关系：time_index = i 时，elapsed_s = offsets_s[i]
"""
struct SimulationTimeGrid
    epoch::SimulationEpoch
    duration_s::Int
    step_s::Int
    offsets_s::Vector{Int}

    function SimulationTimeGrid(epoch::SimulationEpoch, duration_s::Int, step_s::Int)
        # 验证总时长非负
        duration_s >= 0 || throw(ArgumentError("duration_s must be non-negative"))
        # 验证步长为正数
        step_s > 0 || throw(ArgumentError("step_s must be positive"))

        # 生成时间偏移序列：0, step, 2*step, ..., 直到不超过 duration
        offsets_s = collect(0:step_s:duration_s)

        # 若 duration_s 不是 step_s 的整数倍，则在末尾额外加入 duration_s，
        # 确保终点时刻一定被采样
        if isempty(offsets_s) || last(offsets_s) != duration_s
            push!(offsets_s, duration_s)
        end

        return new(epoch, duration_s, step_s, offsets_s)
    end
end

"""
    timeslot_offsets(grid::SimulationTimeGrid) -> Vector{Int}

返回时间网格中每个时间片距离 epoch 的秒数列表。

# 参数
- `grid::SimulationTimeGrid`：时间网格

# 返回值
- `Vector{Int}`：时间偏移量列表
"""
timeslot_offsets(grid::SimulationTimeGrid)::Vector{Int} = grid.offsets_s

"""
    time_count(grid::SimulationTimeGrid) -> Int

返回时间网格中的时间片总数。

# 参数
- `grid::SimulationTimeGrid`：时间网格

# 返回值
- `Int`：时间片数量

# 说明
由于构造时可能添加额外的 duration_s 终点，这个值可能大于 (duration_s / step_s + 1)。
"""
time_count(grid::SimulationTimeGrid)::Int = length(grid.offsets_s)
# 轨道传播器模块。
#
# 本文件定义了项目中的两类核心传播器：
#   1. Sgp4PropagatorAdapter：基于 SGP4 模型和 TLE 轨道根数，调用 SatelliteToolbox/SatelliteToolboxSgp4
#      计算卫星在 TEME 坐标系下的位置与速度。
#   2. EarthFixedNodePropagator：用于"地球固定节点"（如地面站、POP、固定虚拟卫星），
#      把经纬高描述转换为地固 ECEF 位置，再反向旋转到 TEME，保持与星历样本一致的参考系。
#
# 这些传播器是轨道层的核心：输入为 Satellite + SimulationTimeGrid，输出为 EphemerisSample /
# SatelliteEphemeris / ConstellationEphemeris，供网络层进行 ISL/GSL 几何评估。
#
# [算法说明]
# SGP4（Simplified General Perturbations 4）算法基础：
# SGP4是北美防空司令部（NORAD）开发的轨道传播算法，用于预测近地轨道卫星位置。
# 它基于开普勒轨道根数（TLE格式），通过解析公式计算以下摄动效应：
# 1. 地球非球形引力（J2, J3, J4项）：地球不是完美球体，其扁率引起轨道进动；
# 2. 大气阻力：低轨道卫星受大气阻力影响，轨道衰减；
# 3. 日月引力摄动：对高轨道卫星影响较大；
# 4. 太阳辐射压力：对大型卫星有显著影响。
#
# 为什么TLE epoch到目标时间转换使用分钟：
# 1. SGP4算法设计：SGP4内部时间单位是分钟，这是历史设计决定；
# 2. 数值精度：分钟单位在计算轨道摄动时提供合适的数值范围；
# 3. 简化计算：避免频繁的单位转换，提高计算效率。
#
# EarthFixedNodePropagator反向旋转逻辑：
# 地球固定节点（如地面站）在ECEF坐标系中位置固定，但TEME坐标系随地球自转。
# 因此需要：ECEF位置 -> 反向旋转 -> TEME位置
# 这个旋转矩阵与teme_to_ecef中的旋转矩阵互逆：R_TEME_TO_ECEF = R_ECEF_TO_TEME^(-1)
#
# 为什么预初始化sgp4d提高可微性：
# 1. 字符串解析不可微：TLE字符串解析涉及条件分支和字符串操作，无法自动微分；
# 2. 分离初始化与传播：将不可微的初始化步骤移出可微区域；
# 3. 保证梯度连续：预初始化后，传播计算只涉及连续数学运算。
#
# 依赖：
#   - SatelliteToolbox、SatelliteToolboxSgp4：TLE 解析与 SGP4 传播。
#   - SimulationTimeGrid（time.jl）：时间网格定义。
#   - CartesianState、ReferenceFrame（frames.jl）：参考系与状态封装。
#   - EphemerisSample、SatelliteEphemeris、ConstellationEphemeris（ephemeris.jl）：星历容器。
#   - Satellite、Constellation、TLEOrbitElementSet、EarthFixedOrbitElementSet（network_layer/builders.jl 或相关模块）：
#     卫星与轨道根数类型。
#   - validate_satellite_ids（viz/validation_visualization/validation.jl）：星座编号校验。
#     注意：这是核心层对可视化层的反向依赖，未来应迁移到核心层内部。
#     已重构：移除反向依赖，在核心层内部实现简化验证。

import SatelliteToolbox
import SatelliteToolboxSgp4

export AbstractPropagator
export Sgp4PropagatorAdapter
export propagate_sample, propagate_constellation

"""
    AbstractPropagator

所有轨道传播器的抽象基类型。

# [算法说明]
# 轨道传播器设计模式：
# 使用抽象基类型定义传播器接口，具体传播器继承并实现。
#
# 接口方法：
# 1. supports_orbit_elements：声明支持的轨道根数类型
# 2. propagate_sample：计算单个时间片的星历样本
# 3. propagate_satellite：计算单颗卫星的完整星历（可选特化）
#
# 为什么使用抽象类型：
# 1. 多态性：不同传播器可以有不同的实现
# 2. 类型安全：确保传播器实现必要的方法
# 3. 可扩展性：可以添加新的传播器类型
# 4. 代码复用：基类可以提供默认实现
#
# 传播器类型：
# - Sgp4PropagatorAdapter：基于SGP4算法
# - EarthFixedNodePropagator：地球固定节点
# - 未来可以添加：HPOP、SPOT4等
#
# 设计原则：
# - 单一职责：每个传播器只负责一种轨道类型
# - 开闭原则：对扩展开放，对修改关闭
# - 依赖倒置：依赖抽象而不是具体实现

具体子类型必须实现：
- `supports_orbit_elements`：声明支持哪种轨道根数。
- `propagate_sample`：计算单个时间片上的星历样本。
- `propagate_satellite`：计算单颗卫星在整个时间网格上的星历序列（可选提供特化版本以优化性能）。
"""
abstract type AbstractPropagator end

"""
    Sgp4PropagatorAdapter <: AbstractPropagator

基于 SGP4 算法的轨道传播器适配器。

# [算法说明]
# SGP4算法核心思想：
# SGP4使用开普勒轨道根数作为初始条件，通过解析公式计算轨道摄动。
# 主要摄动源：
# 1. 地球非球形引力（J2, J3, J4项）：引起轨道面进动和近地点旋转
# 2. 大气阻力：导致轨道衰减，对低轨道卫星影响显著
# 3. 日月引力：对高轨道卫星有长期影响
# 4. 太阳辐射压力：对大型卫星有显著影响
#
# 为什么使用适配器模式：
# 1. 解耦：隔离SGP4实现细节，提供统一接口
# 2. 可替换：未来可以替换为其他传播器（如SPOT4、HPOP）
# 3. 可测试：适配器可以独立测试，验证与底层库的集成
#
# verify_checksum参数：
# TLE格式包含校验和字段，用于检测传输错误。
# 启用校验和可以避免因TLE转录错误导致的传播失败。
# 但有时TLE数据本身可能有错误，禁用校验和可以处理这些情况。
#
# 适配器模式的好处：
# - 接口统一：所有传播器提供相同接口
# - 实现隔离：底层库变化不影响上层代码
# - 依赖管理：明确依赖SatelliteToolbox库
# - 测试方便：可以模拟底层库进行测试

字段
- `verify_checksum::Bool`：读取 TLE 时是否校验行校验和。默认真，可减少因 TLE 转录错误导致的传播失败。

说明
该适配器将 TLE 行交给 SatelliteToolbox 解析，并通过 SatelliteToolboxSgp4 传播。
为保证可微性，主传播循环会预先初始化 `sgp4d`，避免在可微区域内反复解析字符串。
"""
struct Sgp4PropagatorAdapter <: AbstractPropagator
    verify_checksum::Bool
end

"""
    Sgp4PropagatorAdapter(; verify_checksum=true) -> Sgp4PropagatorAdapter

构造 SGP4 传播器适配器。
"""
Sgp4PropagatorAdapter(; verify_checksum::Bool = true) = Sgp4PropagatorAdapter(verify_checksum)

"""
    EarthFixedNodePropagator <: AbstractPropagator

地球固定节点传播器。

# [算法说明]
# 地球固定节点传播器原理：
# 地球固定节点（如地面站）在ECEF坐标系中位置固定，但网络层需要TEME坐标。
#
# 解决方案：
# 1. 将经纬高转换为ECEF坐标
# 2. 通过反向旋转将ECEF转换为TEME
# 3. 输出与SGP4卫星相同的坐标系
#
# 为什么需要这个传播器：
# 1. 统一参考系：所有位置都在TEME坐标系中表示
# 2. 简化计算：后续ISL/GSL计算可以直接使用
# 3. 避免混合坐标系：确保网络层计算一致性
#
# 与SGP4传播器的比较：
# - SGP4：计算运动卫星的轨道
# - 地球固定：表示静止节点的位置
# - 两者输出格式相同：便于统一处理
#
# 使用场景：
# - 地面站作为通信端点
# - POP（入网点）作为网络节点
# - 固定虚拟卫星作为参考点

用于把地面固定位置（如地面站、POP）表示为"不会绕地球运动的卫星"。
它会将 `EarthFixedOrbitElementSet` 描述的经纬高转为 ECEF，再转到 TEME，
从而与 SGP4 产生的卫星星历处于同一坐标系，方便后续统一计算 GSL 几何。
"""
struct EarthFixedNodePropagator <: AbstractPropagator end

"""
    propagator_name(propagator::AbstractPropagator) -> String

返回传播器类型的字符串名称，用于错误报告与日志。
"""
propagator_name(propagator::AbstractPropagator)::String = string(typeof(propagator))

"""
    supports_orbit_elements(propagator, orbit_elements) -> Bool

判断给定传播器是否支持指定的轨道根数类型。

# [算法说明]
# 传播器与轨道根数的匹配：
# 不同传播器需要不同的轨道根数格式：
# 1. Sgp4PropagatorAdapter：需要TLEOrbitElementSet
#    - TLE包含SGP4所需的完整轨道根数
#    - 格式固定，易于解析
#
# 2. EarthFixedNodePropagator：需要EarthFixedOrbitElementSet
#    - 地球固定节点用经纬高描述
#    - 不是传统轨道根数，而是地理坐标
#
# 为什么需要类型检查：
# 1. 类型安全：防止错误的轨道根数传入传播器
# 2. 错误提示：提供清晰的错误信息
# 3. 扩展性：未来可以添加新的传播器和轨道根数类型
#
# 默认实现：
# 返回false，表示不支持任何轨道根数。
# 子类型必须实现自己的supports_orbit_elements方法。
#
# 使用场景：
# - 传播前检查：确保传播器与轨道根数兼容
# - 错误处理：提前检测问题，提供更好的错误信息
# - 自动选择：根据轨道根数类型自动选择合适的传播器

判断给定传播器是否支持指定的轨道根数类型。

默认对 `AbstractOrbitElementSet` 返回 `false`；
`Sgp4PropagatorAdapter` 仅支持 `TLEOrbitElementSet`；
`EarthFixedNodePropagator` 仅支持 `EarthFixedOrbitElementSet`。
"""
function supports_orbit_elements(
    propagator::AbstractPropagator,
    orbit_elements::AbstractOrbitElementSet,
)::Bool
    return false
end

supports_orbit_elements(::Sgp4PropagatorAdapter, ::TLEOrbitElementSet)::Bool = true
supports_orbit_elements(::EarthFixedNodePropagator, ::EarthFixedOrbitElementSet)::Bool = true

"""
    satellite_toolbox_tle(orbit_elements; verify_checksum=true)

将项目内部的 `TLEOrbitElementSet` 转换为 SatelliteToolbox 可使用的 TLE 对象。

# [算法说明]
# TLE（Two-Line Element Set）格式解析：
# TLE是NORAD发布的标准轨道根数格式，包含：
# 第1行：卫星编号、倾角、升交点赤经、偏心率、近地点幅角、平近点角、运动圈数
# 第2行：大气阻力系数、周期、远地点高度、近地点高度、轨道编号、校验和
#
# 解析过程：
# 1. 读取两行文本
# 2. 提取各个字段（固定宽度格式）
# 3. 转换为数值类型
# 4. 验证校验和（可选）
# 5. 构建TLE对象
#
# 校验和验证：
# TLE每行最后一位是校验和，计算方法：
# 将前68个字符的数字相加，取个位数作为校验和。
# 验证可以检测传输错误，但有时TLE数据本身可能有错误。
#
# 为什么需要这个转换：
# 1. 接口隔离：项目内部使用自己的TLEOrbitElementSet
# 2. 依赖解耦：SatelliteToolbox有自己的TLE格式
# 3. 数据验证：在转换时可以进行额外验证
#
# 错误处理：
# - 校验和错误：可以禁用验证继续处理
# - 格式错误：抛出异常，提示TLE格式问题
# - 缺失字段：使用默认值或抛出异常

参数
- `orbit_elements::TLEOrbitElementSet`：包含 TLE 三行文本的轨道根数。
- `verify_checksum::Bool`：是否校验 TLE 行校验和。

返回值
SatelliteToolbox 的 TLE 对象，供 `sgp4_init` 使用。
"""
function satellite_toolbox_tle(
    orbit_elements::TLEOrbitElementSet;
    verify_checksum::Bool = true,
)
    return SatelliteToolbox.read_tle(
        orbit_elements.line1,
        orbit_elements.line2;
        name = orbit_elements.name,
        verify_checksum = verify_checksum,
    )
end

"""
    elapsed_minutes_since_tle_epoch(tle, time_grid, elapsed_s) -> Float64

计算目标仿真时刻距离 TLE epoch 的分钟数。

# [算法说明]
# 时间转换算法：
# 该函数将仿真时间转换为SGP4算法所需的相对时间（分钟）。
#
# 转换步骤：
# 1. 计算目标时刻的DateTime：
#    target_time = time_grid.epoch + elapsed_s * 1000（毫秒）
#
# 2. 获取TLE历元时间：
#    tle_time = SatelliteToolbox.tle_epoch(DateTime, tle)
#
# 3. 计算时间差（毫秒）：
#    Δt_ms = target_time - tle_time
#
# 4. 转换为分钟：
#    Δt_min = Δt_ms / 60000
#
# 为什么使用分钟作为时间单位：
# 1. SGP4算法设计：内部时间单位是分钟
# 2. 数值稳定性：分钟单位在计算轨道摄动时提供合适的数值范围
# 3. 历史原因：早期计算机使用整数运算，分钟比秒更合适
# 4. 避免精度损失：使用浮点数表示分钟，避免大数值运算
#
# 精度考虑：
# - DateTime精度：毫秒级
# - 分钟转换：除以60000，可能损失精度
# - 实际影响：对于轨道传播，毫秒级精度足够
#
# 为什么不用秒：
# 1. SGP4内部使用分钟，避免频繁转换
# 2. 轨道周期约为90-120分钟，分钟单位更自然
# 3. 早期计算机内存有限，整数运算更快

SGP4 算法以 TLE epoch 为基准，输入时间为"自 epoch 起的分钟数"。
本函数把 `SimulationTimeGrid` 的 `elapsed_s` 先转成 `DateTime`，再与 TLE epoch 求差，
最后除以 60000 得到分钟数。
"""
function elapsed_minutes_since_tle_epoch(tle, time_grid::SimulationTimeGrid, elapsed_s::Int)::Float64
    target_time = time_grid.epoch.instant + Dates.Millisecond(1000 * elapsed_s)
    tle_time = SatelliteToolbox.tle_epoch(DateTime, tle)
    return Dates.value(target_time - tle_time) / 60000
end

"""
    propagate_sample(propagator, satellite, time_grid, time_index) -> EphemerisSample

计算单个时间片上的星历样本。

# [算法说明]
# 基类传播接口：
# 这是传播器的基类接口，子类型必须实现自己的版本。
#
# 接口设计：
# - 输入：传播器、卫星、时间网格、时间索引
# - 输出：EphemerisSample（星历样本）
# - 默认实现：抛出MethodError
#
# 为什么抛出MethodError：
# 1. 强制实现：子类型必须实现自己的版本
# 2. 明确错误：提供清晰的错误信息
# 3. 避免误用：防止使用未实现的传播器
#
# 子类型实现要求：
# - Sgp4PropagatorAdapter：使用SGP4算法
# - EarthFixedNodePropagator：使用坐标转换
#
# 为什么这样设计：
# 1. 接口清晰：明确定义传播器必须提供的功能
# 2. 灵活性：不同传播器可以有不同的实现
# 3. 可扩展性：可以添加新的传播器类型

基类默认抛出 `MethodError`，子类型应提供特化实现。
"""
function propagate_sample(
    propagator::AbstractPropagator,
    satellite::Satellite,
    time_grid::SimulationTimeGrid,
    time_index::Int,
)::EphemerisSample
    throw(
        MethodError(
            propagate_sample,
            (propagator, satellite, time_grid, time_index),
        ),
    )
end

# AD-transparent hot path: accepts a pre-initialised Sgp4Propagator so no
# string parsing happens inside the differentiable region.
"""
    _propagate_sample_sgp4(sgp4d, elapsed_min, satellite_id, time_index, elapsed_s) -> EphemerisSample

SGP4 传播的热路径辅助函数。

# [算法说明]
# SGP4传播热路径详解：
# 这是SGP4传播的核心计算函数，设计用于自动微分（AD）透明。
#
# AD透明的关键设计：
# 1. 输入预初始化：sgp4d是已经初始化的传播器状态，不涉及字符串解析
# 2. 纯数值计算：只包含矩阵运算和数学函数，没有条件分支或字符串操作
# 3. 连续可微：所有运算都是可微的，保证梯度正确传播
#
# SGP4内部计算流程：
# 1. 时间转换：将elapsed_min转换为SGP4内部时间单位
# 2. 轨道根数更新：计算摄动后的轨道根数
# 3. 位置速度计算：使用更新后的根数计算TEME坐标
# 4. 返回结果：位置（km）和速度（km/s）
#
# 为什么这个函数是"热路径"：
# 1. 被频繁调用：每个时间片、每颗卫星都要调用一次
# 2. 计算密集：包含复杂数学运算
# 3. 性能关键：优化这个函数可以显著提高整体性能
#
# 梯度透明的意义：
# 当使用ForwardDiff计算梯度时，这个函数的雅可比矩阵可以直接计算，
# 因为它不包含不可微操作。这使得SGP4传播可以用于基于梯度的优化。

说明
该函数接收已经由 `sgp4_init` 预初始化的传播器状态 `sgp4d`，
避免在自动微分区域内进行字符串解析或初始化操作，从而保证 SGP4 -> 距离 -> 时延链路的梯度透明。
这是 `propagate_satellite(::Sgp4PropagatorAdapter, ...)` 特化版本的核心子调用。
"""
function _propagate_sample_sgp4(
    sgp4d,
    elapsed_min::Number,
    satellite_id::Int,
    time_index::Int,
    elapsed_s::Int,
)::EphemerisSample
    position_km, velocity_km_s = SatelliteToolboxSgp4.sgp4!(sgp4d, elapsed_min)
    return EphemerisSample(
        satellite_id = satellite_id,
        time_index = time_index,
        elapsed_s = elapsed_s,
        cartesian = CartesianState(
            TEME,
            (position_km[1], position_km[2], position_km[3]),
            (velocity_km_s[1], velocity_km_s[2], velocity_km_s[3]),
        ),
    )
end

"""
    propagate_sample(propagator::Sgp4PropagatorAdapter, satellite, time_grid, time_index) -> EphemerisSample

使用 SGP4 算法计算单个时间片样本。

# [算法说明]
# SGP4单点传播流程：
# 1. 解析TLE：将TLE文本转换为内部数据结构（轨道根数）
# 2. 初始化SGP4：创建传播器状态（包含预计算的常数和系数）
# 3. 计算时间差：目标时间 - TLE历元，转换为分钟
# 4. 执行传播：调用SGP4算法计算位置和速度
# 5. 返回结果：封装为EphemerisSample
#
# 为什么每次调用都重新初始化：
# 1. 单点调用场景：不需要批量优化
# 2. 简化实现：避免管理传播器状态
# 3. 正确性保证：避免状态污染
#
# 时间转换详解：
# SGP4算法以TLE历元为基准，输入为"自历元起的分钟数"。
# 转换公式：Δt_min = (target_time - tle_epoch) / 60000
# 其中target_time = epoch + elapsed_s * 1000（毫秒）
#
# 为什么使用分钟作为时间单位：
# 1. SGP4算法设计：内部时间单位是分钟
# 2. 数值稳定性：分钟单位在计算轨道摄动时提供合适的数值范围
# 3. 历史原因：早期计算机使用整数运算，分钟比秒更合适

说明
该函数每次调用都会重新解析 TLE 并初始化 `sgp4d`，适合单点调用场景。
若需批量计算一颗卫星的完整星历，请使用 `propagate_satellite(propagator::Sgp4PropagatorAdapter, ...)`
特化版本以获得更好的性能与可微性。
"""
function propagate_sample(
    propagator::Sgp4PropagatorAdapter,
    satellite::Satellite,
    time_grid::SimulationTimeGrid,
    time_index::Int,
)::EphemerisSample
    checkbounds(timeslot_offsets(time_grid), time_index)
    orbit_elements = satellite.orbit  # 使用新的 orbit 字段
    orbit_elements isa TLEOrbitElementSet ||
        throw(ArgumentError("Sgp4PropagatorAdapter only supports TLEOrbitElementSet"))

    elapsed_s = timeslot_offsets(time_grid)[time_index]
    tle = satellite_toolbox_tle(orbit_elements; verify_checksum = propagator.verify_checksum)
    elapsed_min = elapsed_minutes_since_tle_epoch(tle, time_grid, elapsed_s)
    sgp4d = SatelliteToolboxSgp4.sgp4_init(tle)
    return _propagate_sample_sgp4(sgp4d, elapsed_min, satellite.id, time_index, elapsed_s)
end

"""
    earth_fixed_node_longitude_deg(elements::EarthFixedOrbitElementSet) -> Float64

计算地球固定节点的等效地心经度。

# [算法说明]
# 地球固定节点的经度计算：
# 对于地球固定节点（如地面站），轨道根数被重新解释：
# - inclination_deg：纬度（不是倾角）
# - raan_deg：经度相关分量1
# - argument_of_perigee_deg：经度相关分量2
# - mean_anomaly_deg：经度相关分量3
#
# 经度计算公式：
# longitude = (raan_deg + argument_of_perigee_deg + mean_anomaly_deg) mod 360
#
# 为什么这样计算：
# 1. 地球固定节点在ECEF坐标系中位置固定；
# 2. 通过组合三个角度分量，可以表示任意经度；
# 3. mod 360确保结果在[0, 360)范围内。
#
# 物理意义：
# 这个计算相当于将三个角度分量投影到赤道平面上，
# 得到节点在地球表面的经度位置。

对于地球固定节点，轨道根数中的倾角、升交点赤经、近地点幅角、平近点角被重新解释为
纬度、经度相关分量。本函数把后三者相加再对 360 取模，得到节点在地固系中的经度。
"""
earth_fixed_node_longitude_deg(elements::EarthFixedOrbitElementSet)::Float64 =
    mod(elements.raan_deg + elements.argument_of_perigee_deg + elements.mean_anomaly_deg, 360)

"""
    earth_fixed_node_position_ecef_km(elements::EarthFixedOrbitElementSet) -> Vector{Float64}

把地球固定节点的经纬高转换为 ECEF 三维位置（单位 km）。

# [算法说明]
# 地球固定节点位置计算：
# 该函数将地理坐标（经纬高）转换为ECEF笛卡尔坐标。
#
# 坐标映射：
# - inclination_deg → 纬度φ（不是倾角，而是地理纬度）
# - earth_fixed_node_longitude_deg → 经度λ
# - altitude_km → 高度h
#
# 转换公式（WGS84椭球体）：
# X = (N(φ) + h) * cos(φ) * cos(λ)
# Y = (N(φ) + h) * cos(φ) * sin(λ)
# Z = (N(φ)(1 - e²) + h) * sin(φ)
#
# 其中：
# - N(φ) = a / √(1 - e²sin²(φ))：卯酉圈曲率半径
# - a = 6378.137 km：地球长半轴
# - e² = 0.00669437999014：第一偏心率平方
#
# 为什么需要这个转换：
# 1. ECEF坐标便于计算距离和仰角
# 2. 与SGP4卫星位置在同一坐标系
# 3. 为后续反向旋转到TEME做准备
#
# 精度分析：
# - WGS84模型精度：毫米级
# - 计算精度：双精度浮点数，足够
# - 忽略极移：误差约1米

这里把 `elements.inclination_deg` 当作纬度，`earth_fixed_node_longitude_deg(elements)` 当作经度，
`elements.altitude_km` 当作高度，再调用 `geodetic_to_ecef_km` 完成转换。
"""
earth_fixed_node_position_ecef_km(elements::EarthFixedOrbitElementSet)::Vector{Float64} =
    geodetic_to_ecef_km(
        GeodeticPosition(
            elements.inclination_deg,
            earth_fixed_node_longitude_deg(elements),
            elements.altitude_km,
        ),
    )

"""
    propagate_sample(::EarthFixedNodePropagator, satellite, time_grid, time_index) -> EphemerisSample

计算地球固定节点在单个时间片上的星历样本。

# [算法说明]
# 地球固定节点传播器的核心逻辑：
# 问题：地面站在ECEF坐标系中位置固定，但网络层需要TEME坐标系下的位置。
# 解决方案：通过反向旋转将ECEF位置转换到TEME坐标系。
#
# 旋转过程：
# 1. 计算目标时刻的格林威治恒星时GMST(t)
# 2. 构造ECEF到TEME的旋转矩阵R⁻¹(θ)
# 3. P_TEME = R⁻¹(θ) * P_ECEF
#
# 为什么需要这个转换：
# 1. 统一参考系：所有卫星位置（包括SGP4卫星）都在TEME坐标系中表示；
# 2. 简化计算：后续ISL/GSL计算可以直接使用TEME坐标；
# 3. 避免混合坐标系：确保网络层计算的一致性。
#
# 时间依赖性：
# 虽然地面站在ECEF中固定，但在TEME中位置随时间变化，
# 因为TEME坐标系随地球自转而旋转。
#
# 实现细节：
# 1. 使用geodetic_to_ecef_km将经纬高转换为ECEF坐标
# 2. 使用sv_ecef_to_eci将ECEF转换到TEME
# 3. 速度为零：地面站相对于地球静止
#
# 误差分析：
# - 旋转矩阵精度：取决于GMST计算精度
# - 地球模型：使用WGS84椭球体
# - 忽略极移：简化模型，误差约1米量级

地球固定节点的 ECEF 位置不随时间变化，但 TEME 坐标系随地球自转而变化。
因此需要先得到 ECEF 位置，再用 `sv_ecef_to_eci` 转到 TEME，
保证输出与 SGP4 卫星样本使用相同的参考系，便于后续链路计算统一处理。
"""
function propagate_sample(
    ::EarthFixedNodePropagator,
    satellite::Satellite,
    time_grid::SimulationTimeGrid,
    time_index::Int,
)::EphemerisSample
    checkbounds(timeslot_offsets(time_grid), time_index)
    orbit_elements = satellite.orbit
    orbit_elements isa EarthFixedOrbitElementSet ||
        throw(ArgumentError("EarthFixedNodePropagator only supports EarthFixedOrbitElementSet"))

    elapsed_s = timeslot_offsets(time_grid)[time_index]
    time = target_datetime(time_grid, elapsed_s)
    jd = julian_day(time)
    position_ecef_km = earth_fixed_node_position_ecef_km(orbit_elements)
    # 地球固定节点速度为零；构造 OrbitStateVector 是为了调用 SatelliteToolbox 的参考系转换接口。
    state_ecef = SatelliteToolbox.OrbitStateVector(
        jd,
        position_ecef_km,
        [0.0, 0.0, 0.0],
    )
    # 从地固系（PEF）转到惯性系（TEME），此时得到的 TEME 位置会随时间旋转。
    state_teme = SatelliteToolbox.sv_ecef_to_eci(
        state_ecef,
        SatelliteToolbox.PEF(),
        SatelliteToolbox.TEME(),
        jd,
    )

    return EphemerisSample(
        satellite_id = satellite.id,
        time_index = time_index,
        elapsed_s = elapsed_s,
        cartesian = CartesianState(
            TEME,
            Tuple(Float64(x) for x in state_teme.r),
            Tuple(Float64(x) for x in state_teme.v),
        ),
    )
end

"""
    propagate_satellite(propagator, satellite, time_grid) -> SatelliteEphemeris

计算单颗卫星在整个仿真时间网格上的星历序列。

# [算法说明]
# 基类传播算法：
# 这是传播器的基类实现，逐时间片调用propagate_sample。
#
# 算法流程：
# 1. 验证传播器与轨道根数兼容性
# 2. 创建空结果数组
# 3. 遍历时间网格：
#    - 对每个时间片调用propagate_sample
#    - 收集结果到数组
# 4. 构建SatelliteEphemeris对象
#
# 为什么需要基类实现：
# 1. 提供默认实现：子类可以选择重写或继承
# 2. 代码复用：避免重复编写循环逻辑
# 3. 一致性：确保所有传播器有相同的行为
#
# 与特化版本的比较：
# - 基类：每次调用都重新初始化（简单但低效）
# - 特化：只初始化一次，循环传播（高效但复杂）
#
# 性能考虑：
# - 时间复杂度：O(T)，其中T是时间片数量
# - 空间复杂度：O(T)，存储所有时间片的结果
# - 优化空间：可以并行化时间片处理
#
# 为什么Sgp4PropagatorAdapter需要特化版本：
# 1. 性能：避免重复解析TLE字符串
# 2. 可微性：将不可微操作移出可微区域
# 3. 内存：避免重复分配传播器状态

基类实现会逐时间片调用 `propagate_sample`。`Sgp4PropagatorAdapter` 提供了特化版本，
预先初始化 SGP4 状态以减少重复解析。
"""
function propagate_satellite(
    propagator::AbstractPropagator,
    satellite::Satellite,
    time_grid::SimulationTimeGrid,
)::SatelliteEphemeris
    supports_orbit_elements(propagator, satellite.orbit) ||
        throw(
            ArgumentError(
                "$(propagator_name(propagator)) does not support $(typeof(satellite.orbit))",
            ),
        )

    samples = [
        propagate_sample(propagator, satellite, time_grid, time_index)
        for time_index in 1:time_count(time_grid)
    ]
    return SatelliteEphemeris(satellite.id, samples)
end

# Sgp4-specific override: parse TLE once per satellite, then loop over time
# slots with the pre-initialised propagator (no string parsing in the hot path).
"""
    propagate_satellite(propagator::Sgp4PropagatorAdapter, satellite, time_grid) -> SatelliteEphemeris

SGP4 批量星历计算特化版本。

# [算法说明]
# SGP4批量传播优化：
# 与基类实现相比，本函数进行了关键优化：
#
# 优化1：TLE只解析一次
# - 基类实现：每个时间片都解析TLE字符串
# - 优化实现：只在开始时解析一次TLE
# - 性能提升：避免重复字符串解析，节省时间
#
# 优化2：SGP4只初始化一次
# - 基类实现：每个时间片都初始化SGP4传播器
# - 优化实现：只初始化一次，然后复用
# - 内存节省：避免重复分配传播器状态
#
# 优化3：时间循环优化
# - 预计算时间偏移量：避免重复计算
# - 连续内存访问：提高缓存命中率
# - 向量化潜力：为未来SIMD优化留下空间
#
# 为什么这样设计：
# 1. 性能：批量处理比单点处理更高效
# 2. 可微性：将不可微操作（字符串解析）移出可微区域
# 3. 数值稳定性：相同传播器状态确保数值一致性
#
# 时间复杂度分析：
# - TLE解析：O(1)
# - SGP4初始化：O(1)
# - 时间循环：O(T)，其中T是时间片数量
# - 总时间复杂度：O(T)
#
# 与基类实现的比较：
# - 基类：O(T × (parse_cost + init_cost))
# - 优化：O(T + parse_cost + init_cost)
# 当T较大时，优化效果显著。

说明
相比基类实现，本函数只解析一次 TLE、初始化一次 `sgp4d`，然后在时间网格上循环传播。
这样做有两个好处：
1. 性能：避免每个时间片重复解析字符串。
2. 可微性：把字符串解析排除在可微区域之外，使 `_propagate_sample_sgp4` 的梯度透明。
"""
function propagate_satellite(
    propagator::Sgp4PropagatorAdapter,
    satellite::Satellite,
    time_grid::SimulationTimeGrid,
)::SatelliteEphemeris
    orbit_elements = satellite.orbit
    orbit_elements isa TLEOrbitElementSet ||
        throw(ArgumentError("Sgp4PropagatorAdapter only supports TLEOrbitElementSet"))

    tle = satellite_toolbox_tle(orbit_elements; verify_checksum = propagator.verify_checksum)
    sgp4d = SatelliteToolboxSgp4.sgp4_init(tle)

    offsets = timeslot_offsets(time_grid)
    samples = Vector{EphemerisSample}(undef, time_count(time_grid))
    for time_index in 1:time_count(time_grid)
        elapsed_s = offsets[time_index]
        elapsed_min = elapsed_minutes_since_tle_epoch(tle, time_grid, elapsed_s)
        samples[time_index] = _propagate_sample_sgp4(
            sgp4d, elapsed_min, satellite.id, time_index, elapsed_s,
        )
    end
    return SatelliteEphemeris(satellite.id, samples)
end

"""
    propagate_constellation(propagator, constellation, time_grid) -> ConstellationEphemeris

计算整个星座在所有时间片上的星历表。

# [算法说明]
# 星座传播算法：
# 该函数实现整个星座的批量轨道传播。
#
# 算法流程：
# 1. 验证星座完整性：
#    - 调用validate_satellite_ids检查卫星编号连续性
#    - 确保所有卫星ID从1开始连续编号
#
# 2. 并行传播：
#    - 对每颗卫星独立调用propagate_satellite
#    - 各卫星传播相互独立，可并行化
#    - 收集所有卫星的SatelliteEphemeris
#
# 3. 构建结果：
#    - 创建ConstellationEphemeris
#    - 确保卫星顺序与ID对应
#
# 为什么需要这个函数：
# 1. 批处理：一次性传播整个星座，避免多次调用
# 2. 一致性：确保所有卫星使用相同的时间网格
# 3. 验证：在传播前检查星座完整性
# 4. 性能：为并行优化提供统一入口
#
# 性能考虑：
# 对于大型星座（如Starlink的数千颗卫星），
# 这个函数可能很耗时。优化方向：
# 1. 并行计算：利用多核CPU
# 2. GPU加速：使用GPU进行轨道传播
# 3. 缓存机制：避免重复计算
#
# 内存管理：
# - 预分配数组：避免动态扩容
# - 就地更新：减少内存分配
# - 垃圾回收：及时释放不再使用的内存

参数
- `propagator::AbstractPropagator`：使用的传播器。
- `constellation::Constellation`：待传播的星座。
- `time_grid::SimulationTimeGrid`：仿真时间网格。

返回值
`ConstellationEphemeris`，包含每颗卫星的 `SatelliteEphemeris`。

说明
对 `constellation`（Vector{Satellite}）中的每颗卫星调用 `propagate_satellite`。
卫星编号必须连续（1到N），否则星历索引会出错。
"""
function propagate_constellation(
    propagator::AbstractPropagator,
    constellation::Vector{Satellite},
    time_grid::SimulationTimeGrid,
    constellation_name::String="unnamed",  # 新增：星座名称参数
)::ConstellationEphemeris
    # 验证卫星编号连续性（简化版，不依赖可视化层）
    sat_list = constellation  # Constellation 就是 Vector{Satellite}
    for (i, sat) in enumerate(sat_list)
        if sat.id != i
            throw(ArgumentError("satellite id must be continuous from 1 to N: got id=$(sat.id) at index=$i"))
        end
    end

    n_sats = length(sat_list)
    satellite_ephemerides = Vector{SatelliteEphemeris}(undef, n_sats)
    Threads.@threads for i in 1:n_sats
        satellite_ephemerides[i] = propagate_satellite(propagator, sat_list[i], time_grid)
    end
    return ConstellationEphemeris(constellation_name, time_grid, satellite_ephemerides)
end

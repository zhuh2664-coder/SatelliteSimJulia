# 星历数据容器模块。
#
# **CI 契约（Phase 2a）**：新代码须走裸 `Array{Float64,3}` 主路径（`propagate_to_ecef` 等）。
# 本文件的 `ConstellationEphemeris` 嵌套类型仅保留兼容，不再新增调用方。
#   - EphemerisSample：单个卫星在单个时间片的星历样本。
#   - SatelliteEphemeris：单颗卫星在整个时间网格上的星历序列。
#   - ConstellationEphemeris：整个星座在所有时间片上的星历表。
#
# 这些结构是"轨道物理"到"网络几何"的边界：轨道传播器负责填充它们，
# 网络层的 ISL/GSL 评估、可视化、路由等模块负责消费它们。

export EphemerisSample, SatelliteEphemeris, ConstellationEphemeris
export ephemeris_samples
#
# [算法说明]
# 二维索引结构（卫星×时间）：
# ConstellationEphemeris本质上是一个二维数组，第一维是卫星索引（1到N），
# 第二维是时间索引（1到T）。这种设计使得：
# 1. 高效访问：ephemeris[sat_id, time_id]或ephemeris[sat_id][time_id]；
# 2. 内存连续：按卫星顺序存储，有利于缓存局部性；
# 3. 语义清晰：直接对应"某颗卫星在某时刻的状态"。
#
# 为什么样本必须按time_index顺序排列：
# 1. 算法依赖：后续的时间序列分析（如差分、积分）依赖时间单调性；
# 2. 索引约定：ephemeris[sat][time_index]直接索引，要求time_index==数组下标；
# 3. 数据完整性：确保每个时间片都有对应样本，避免计算错误。
#
# attach_geodetic转换链：
# 这个函数实现了从笛卡尔坐标到地理坐标的完整转换链：
# 1. TEME笛卡尔坐标 -> ECEF笛卡尔坐标（通过旋转矩阵）
# 2. ECEF笛卡尔坐标 -> WGS84经纬高（通过迭代算法）
# 这个链确保了不同参考系之间的正确转换。
#
# 依赖：
#   - SimulationTimeGrid（time.jl）：时间网格与 epoch 管理。
#   - CartesianState、GeodeticPosition、AbstractFrameTransform、ReferenceFrame（frames.jl）：
#     坐标状态与参考系转换接口。

# 单个星历样本。
#
# 可以把它理解成"某一颗卫星在某一个时间片的状态记录"。轨道传播器每算出一次卫星位置，
# 就会形成一个 EphemerisSample。后续网络层计算 ISL/GSL 时，主要消费这里的 cartesian 位置。
#
# [算法说明]
# 星历样本设计：
# 这是轨道层输出的最小数据单元，包含卫星在特定时刻的状态。
#
# 字段设计：
# 1. satellite_id：标识卫星
# 2. time_index：时间片索引（用于快速查找）
# 3. elapsed_s：累计时间（用于物理计算）
# 4. cartesian：笛卡尔坐标（主要数据）
# 5. geodetic：地理坐标（可选，用于可视化）
#
# 为什么需要两种坐标：
# - 笛卡尔坐标：用于ISL/GSL几何计算（距离、仰角）
# - 地理坐标：用于可视化、星下点分析
#
# 数据冗余：
# - time_index和elapsed_s都表示时间，但用途不同
# - time_index用于索引，elapsed_s用于物理计算
# - 这种冗余提高了使用便利性
#
# 不可变设计：
# - 结构体是不可变的，一旦创建不能修改
# - 确保数据一致性
# - 便于缓存和优化
struct EphemerisSample
    # 全星座唯一卫星编号。它必须和 Satellite.id 对齐，方便后续用数组下标直接索引。
    satellite_id::Int

    # 当前样本在时间网格中的序号，从 1 开始。它不是秒数，而是第几个 time slot。
    time_index::Int

    # 当前样本距离仿真 epoch 的秒数。例如 elapsed_s = 60 表示 epoch 后 60 秒。
    elapsed_s::Int

    # 笛卡尔状态，通常包含 TEME 或 ECEF 坐标系下的位置和速度。
    # 轨道传播器最初会给出 TEME；网络层常用的是转换后的 ECEF。
    cartesian::Union{Nothing,CartesianState}

    # 经纬高状态，可选。它主要用于可视化、星下点分析或地理解释，
    # 不是每个网络层计算都必须依赖它。
    geodetic::Union{Nothing,GeodeticPosition}

    function EphemerisSample(;
        satellite_id::Int,
        time_index::Int,
        elapsed_s::Int,
        cartesian::Union{Nothing,CartesianState} = nothing,
        geodetic::Union{Nothing,GeodeticPosition} = nothing,
    )
        # 这里做的是数据结构边界检查：星历样本必须属于一颗有效卫星和一个有效时间片。
        satellite_id > 0 || throw(ArgumentError("satellite_id must be positive"))
        time_index > 0 || throw(ArgumentError("time_index must be positive"))
        elapsed_s >= 0 || throw(ArgumentError("elapsed_s must be non-negative"))

        # 一个样本至少要有一种空间位置表达。只有时间和卫星编号而没有位置，对后续链路计算没有意义。
        cartesian !== nothing || geodetic !== nothing ||
            throw(ArgumentError("at least one of cartesian or geodetic must be provided"))
        return new(satellite_id, time_index, elapsed_s, cartesian, geodetic)
    end
end

# 单颗卫星在整个仿真时间网格上的星历序列。
#
# 可以把它理解成：
#
#     某颗卫星 -> [t1 样本, t2 样本, t3 样本, ...]
#
# 它保证所有样本都属于同一颗卫星，并且样本顺序严格等于 time_index。
#
# [算法说明]
# 卫星星历序列设计：
# 这是单颗卫星的时间序列数据，包含所有时间片的状态。
#
# 数据结构：
# - samples：Vector{EphemerisSample}
# - 顺序：按time_index递增
# - 约束：所有样本属于同一卫星
#
# 为什么需要这种结构：
# 1. 时间序列分析：计算卫星轨迹、速度变化
# 2. 批量处理：一次性处理整颗卫星的数据
# 3. 数据完整性：确保时间序列连续
#
# 索引约定：
# - samples[i] 对应 time_index = i
# - 这个约定使得索引高效（O(1)）
# - 构造时验证此约定
#
# 与ConstellationEphemeris的关系：
# - SatelliteEphemeris是单颗卫星的时间序列
# - ConstellationEphemeris是多颗卫星的集合
# - 可以看作二维数组的一行
#
# 使用场景：
# - 轨道传播：输出单颗卫星的星历
# - 轨迹分析：分析卫星运动特性
# - 可视化：绘制卫星轨迹
struct SatelliteEphemeris
    # 这条时间序列属于哪颗卫星。
    satellite_id::Int

    # 这颗卫星在每个时间片上的状态样本。
    samples::Vector{EphemerisSample}

    function SatelliteEphemeris(satellite_id::Int, samples::Vector{EphemerisSample})
        satellite_id > 0 || throw(ArgumentError("satellite_id must be positive"))
        !isempty(samples) || throw(ArgumentError("SatelliteEphemeris must contain at least one sample"))
        for (index, sample) in pairs(samples)
            # 防止把别的卫星样本混进当前卫星的时间序列。
            sample.satellite_id == satellite_id ||
                throw(ArgumentError("all samples must belong to satellite_id"))

            # 防止样本顺序和时间片编号不一致。后续 ephemeris[sat][time] 会依赖这个约定。
            sample.time_index == index ||
                throw(ArgumentError("sample time_index must match sample order"))
        end
        return new(satellite_id, samples)
    end
end

# 整个星座在整个仿真时间网格上的星历表。
#
# 这是轨道层交给网络层的核心数据结构。可以把它理解成一个二维表：
#
#     卫星编号 × 时间片 -> EphemerisSample
#
# 网络层后续计算 ISL 时，会取同一时间片下两颗卫星的位置；
# 计算 GSL 时，会取某一时间片下卫星位置和地面站位置之间的几何关系。
#
# [算法说明]
# 二维索引结构详解：
# ConstellationEphemeris本质上是一个矩阵，行表示卫星，列表示时间。
# 例如：ephemeris[i][j]表示第i颗卫星在第j个时间片的状态。
#
# 这种设计的优点：
# 1. 高效访问：O(1)时间复杂度获取任意卫星在任意时间的状态
# 2. 内存连续：按卫星顺序存储，有利于CPU缓存预取
# 3. 批量处理：可以方便地处理整颗卫星的时间序列或整个时间片的卫星状态
#
# 内存布局示例（2颗卫星，3个时间片）：
# [sat1_t1, sat1_t2, sat1_t3, sat2_t1, sat2_t2, sat2_t3]
# 这种布局使得按卫星遍历（网络层常见操作）具有良好的局部性。
#
# 为什么需要这种结构：
# 1. 网络层计算需要同时访问多颗卫星在同一时间的状态（如ISL距离计算）
# 2. 可视化需要某颗卫星的完整轨迹
# 3. 统计分析需要整个星座的时空分布
struct ConstellationEphemeris
    # 星座名称，通常来自配置或 TLE 星座构建过程。
    constellation_name::String

    # 仿真时间网格。它定义 epoch、总时长、步长，以及每个 time_index 对应的 elapsed_s。
    time_grid::SimulationTimeGrid

    # 每颗卫星对应一条 SatelliteEphemeris。数组顺序必须和 global satellite id 对齐。
    satellites::Vector{SatelliteEphemeris}

    function ConstellationEphemeris(
        constellation_name::String,
        time_grid::SimulationTimeGrid,
        satellites::Vector{SatelliteEphemeris},
    )
        !isempty(constellation_name) || throw(ArgumentError("constellation_name must not be empty"))
        !isempty(satellites) || throw(ArgumentError("ConstellationEphemeris must contain at least one satellite"))

        expected_time_count = time_count(time_grid)
        for (index, satellite_ephemeris) in pairs(satellites)
            # 这里强制“数组下标 == 全局卫星编号”。这个约定让网络层可以高效地按 satellite_id 取位置。
            satellite_ephemeris.satellite_id == index ||
                throw(ArgumentError("satellite ephemeris order must match global satellite id"))

            # 每颗卫星都必须覆盖完整时间网格，否则某些时间片的链路计算会缺数据。
            length(satellite_ephemeris.samples) == expected_time_count ||
                throw(ArgumentError("each satellite ephemeris must match the time grid length"))
        end

        return new(constellation_name, time_grid, satellites)
    end
end

# 让 SatelliteEphemeris 和 ConstellationEphemeris 可以像普通容器一样使用 length(...)。
Base.length(ephemeris::SatelliteEphemeris)::Int = length(ephemeris.samples)
Base.length(ephemeris::ConstellationEphemeris)::Int = length(ephemeris.satellites)

# 支持 ephemeris[time_index] 读取单颗卫星在某个时间片的样本。
Base.getindex(ephemeris::SatelliteEphemeris, time_index::Int)::EphemerisSample =
    ephemeris.samples[time_index]

# 支持 ephemeris[satellite_id] 读取某颗卫星的整条时间序列。
Base.getindex(ephemeris::ConstellationEphemeris, satellite_id::Int)::SatelliteEphemeris =
    ephemeris.satellites[satellite_id]

# 支持 ephemeris[satellite] 这种更语义化的读取方式。
Base.getindex(ephemeris::ConstellationEphemeris, satellite::Satellite)::SatelliteEphemeris =
    ephemeris[satellite.id]

# 把“全星座 × 全时间片”的二维星历表摊平成一维样本列表。
# 这适合做导出、统计或遍历，但网络层按时间片计算时通常会直接索引 ConstellationEphemeris。
#
# [算法说明]
# 二维到一维展平算法：
# 该函数将ConstellationEphemeris的二维结构展平为一维列表。
#
# 展平顺序：
# 先按卫星遍历，再按时间遍历：
# [sat1_t1, sat1_t2, ..., sat1_tT, sat2_t1, sat2_t2, ..., sat2_tT, ...]
#
# 为什么需要展平：
# 1. 序列化：便于导出为文件格式
# 2. 统计分析：计算全局统计量
# 3. 遍历处理：简单遍历所有样本
# 4. 数据交换：与其他系统交互
#
# 性能考虑：
# - 时间复杂度：O(N × T)，N是卫星数，T是时间片数
# - 空间复杂度：O(N × T)，创建新列表
# - 内存分配：一次分配整个列表
#
# 使用场景：
# - 数据导出：保存到CSV或JSON文件
# - 统计计算：计算平均距离、最大延迟等
# - 可视化：绘制所有卫星的轨迹
# - 调试：查看所有样本数据
#
# 与直接索引的比较：
# - 展平：适合全局操作，但内存开销大
# - 直接索引：适合局部操作，内存效率高
# 根据具体需求选择合适的方法。
function ephemeris_samples(ephemeris::ConstellationEphemeris)::Vector{EphemerisSample}
    return [sample for satellite_ephemeris in ephemeris.satellites for sample in satellite_ephemeris.samples]
end

# 给单个星历样本补充经纬高信息。
#
# 注意：这个函数不会丢掉原来的 cartesian 状态，而是返回一个新样本，
# 在原有位置/速度之外附加 geodetic 字段。
#
# [算法说明]
# attach_geodetic转换链详解：
# 该函数实现了从轨道状态到地理坐标的完整转换链：
# 1. 输入：TEME笛卡尔坐标 (x, y, z) 和时间t
# 2. 第一步：TEME → ECEF转换（通过旋转矩阵R）
#    - 计算格林威治恒星时θ(t) = GMST(t)
#    - 构造旋转矩阵R(θ)
#    - P_ECEF = R(θ) * P_TEME
# 3. 第二步：ECEF → 经纬高转换（通过迭代算法）
#    - 计算经度λ = atan2(Y, X)
#    - 迭代计算纬度φ和高度h
# 4. 输出：经纬高 (latitude, longitude, altitude)
#
# 为什么需要时间信息：
# 1. 旋转矩阵R依赖于时间t（通过GMST）；
# 2. 不同时间点，相同的TEME坐标对应不同的ECEF坐标；
# 3. 地球自转使得坐标转换具有时间依赖性。
function attach_geodetic(
    sample::EphemerisSample,
    transform::AbstractFrameTransform,
    time_grid::SimulationTimeGrid,
)::EphemerisSample
    sample.cartesian !== nothing ||
        throw(ArgumentError("cannot attach geodetic position without a CartesianState"))

    # 经纬高转换需要知道样本对应的真实时间，因为 TEME -> ECEF 的参考系转换和地球自转有关。
    geodetic = geodetic_position(
        transform,
        sample.cartesian,
        target_datetime(time_grid, sample.elapsed_s),
    )
    return EphemerisSample(
        satellite_id = sample.satellite_id,
        time_index = sample.time_index,
        elapsed_s = sample.elapsed_s,
        cartesian = sample.cartesian,
        geodetic = geodetic,
    )
end

# 给单颗卫星的整条星历序列补充经纬高信息。
#
# [算法说明]
# 批量经纬高转换：
# 这个函数对整颗卫星的时间序列进行批量转换。
# 算法流程：
# 1. 遍历卫星的所有时间片样本
# 2. 对每个样本调用单样本attach_geodetic函数
# 3. 收集结果，构建新的SatelliteEphemeris
#
# 为什么需要批量转换：
# 1. 代码复用：避免重复编写循环逻辑
# 2. 性能优化：可以并行化处理（未来优化）
# 3. 一致性保证：确保所有样本使用相同的转换参数
#
# 内存管理：
# 使用列表推导式创建新样本，避免修改原数据（不可变性）。
function attach_geodetic(
    ephemeris::SatelliteEphemeris,
    transform::AbstractFrameTransform,
    time_grid::SimulationTimeGrid,
)::SatelliteEphemeris
    return SatelliteEphemeris(
        ephemeris.satellite_id,
        [attach_geodetic(sample, transform, time_grid) for sample in ephemeris.samples],
    )
end

# 给整个星座的星历表补充经纬高信息。
#
# 这一步常用于可视化、星下点分析和地理解释。对 GSL/ISL 的核心几何计算来说，
# 更关键的是 cartesian 中的 ECEF 位置。
#
# [算法说明]
# 星座级批量转换：
# 这个函数对整个星座的所有卫星进行批量转换。
# 算法流程：
# 1. 遍历星座的所有卫星
# 2. 对每颗卫星调用卫星级attach_geodetic函数
# 3. 收集结果，构建新的ConstellationEphemeris
#
# 为什么需要星座级转换：
# 1. 可视化需求：需要所有卫星的星下点轨迹
# 2. 分析需求：需要整个星座的地理分布
# 3. 批处理：一次性完成所有转换，避免重复调用
#
# 性能考虑：
# 对于大型星座（如Starlink），这个操作可能很耗时。
# 未来可以考虑：①并行处理；②延迟计算；③缓存结果。
function attach_geodetic(
    ephemeris::ConstellationEphemeris,
    transform::AbstractFrameTransform,
)::ConstellationEphemeris
    return ConstellationEphemeris(
        ephemeris.constellation_name,
        ephemeris.time_grid,
        [
            attach_geodetic(satellite_ephemeris, transform, ephemeris.time_grid)
            for satellite_ephemeris in ephemeris.satellites
        ],
    )
end

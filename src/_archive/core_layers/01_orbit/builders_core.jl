"""
    网络层 / 星座构建入口模块

将外部规格（设计参数、TLE 记录或 TLE 自动分面）转换为项目统一的
静态星座对象 `Constellation`。本文件承担"规格 → 身份与轨道参数"的职责，
是网络层数据流的最上游。对于设计规格，实际轨道参数生成委托给 design_orbit_generation.jl；
对于 TLE 数据，则通过读取轨道根数并按 RAAN 自动分轨道面，生成 `SatelliteId` 分层索引。

# 算法说明

## RAAN 自动分轨道面算法
对于 TLE 数据，需要将卫星自动分组到不同的轨道面。
算法基于升交点赤经（RAAN）进行聚类，因为同一轨道面的卫星具有相同的 RAAN。

### 算法流程
1. 圆域旋转（Circular Gap Rotation）：
   - RAAN 是角度值，359° 和 1° 之间只差 2°，但线性排序会产生 358° 的伪间隙
   - 算法在圆域 [0, 360) 上找到最大间隙，将旋转原点设在最大间隙之后
   - 这确保真实的大间隙不被 0°/360° 边界割裂

2. Jenks 自然断点法聚类：
   - 对旋转后的 RAAN 进行排序，使用 Jenks 自然断点法将数据分成若干类
   - 每个类对应一个轨道面，类内 RAAN 差异最小，类间差异最大
   - 使用动态规划保证全局最优断点

3. 面内排序：
   - 每个轨道面内的卫星按升交角距（argument of latitude）排序
   - 升交角距 = 近地点幅角 + 平均近点角
   - 这确保面内卫星按轨道位置顺序排列

### 面数推断
当未指定轨道面数量时，算法通过以下方式自动推断：
1. 计算相邻 RAAN 之间的间隙
2. 找到显著大间隙（> 3 倍中位数间隙且 ≥ 0.5°）
3. 大间隙数量 + 1 = 轨道面数量
4. 用 min_satellites_per_plane 约束面数上限

## SatelliteId 分层索引
每颗卫星分配一个分层身份标识 SatelliteId：
- global_id：全局唯一递增 ID
- shell_id：所属壳层 ID
- shell_local_id：壳层内本地 ID
- orbit_plane_id：所属轨道面 ID
- plane_local_slot：轨道面内槽位序号

这种分层索引支持高效的拓扑查询和路由计算。
"""

abstract type AbstractConstellationBuilder end

using Statistics
import SatelliteToolbox

"""
    DesignConstellationBuilder <: AbstractConstellationBuilder

根据设计规格 `ConstellationSpec` 构建静态星座的构建器。

# 字段
- `source::String`: 数据来源标识，固定为 `"design"`。

# 依赖
- 构造逻辑委托给 `build_design_constellation`（定义于 design_orbit_generation.jl）。
"""
struct DesignConstellationBuilder <: AbstractConstellationBuilder
    source::String
end

DesignConstellationBuilder() = DesignConstellationBuilder("design")

"""
    TLEConstellationBuilder <: AbstractConstellationBuilder

按“每条 TLE 记录作为一个独立轨道面”的方式构建星座的构建器。

# 字段
- `source::String`: 数据来源标识，固定为 `"tle"`。

# 说明
- 该构建器不对卫星进行轨道面分组，适合 TLE 记录本身已按面排序或无需分面的场景。
"""
struct TLEConstellationBuilder <: AbstractConstellationBuilder
    source::String
end

TLEConstellationBuilder() = TLEConstellationBuilder("tle")

"""
    TLEOrbitPlaneGroupingConfig

TLE 自动分轨道面构建器的配置参数。

# 字段
- `expected_planes::Union{Nothing,Int}`: 期望的轨道面数量；为 `nothing` 时自动推断。
- `min_satellites_per_plane::Int`: 每个轨道面的最少卫星数，用于约束自动推断的面数上限。
- `verify_checksum::Bool`: 是否校验 TLE 行的校验和。
- `warn_unbalanced_planes::Bool`: 当面内卫星数显著低于平均值时是否发出警告。
- `plane_count_warning_ratio::Float64`: 触发不平衡警告的阈值比例（低于平均值的该比例时警告）。
"""
struct TLEOrbitPlaneGroupingConfig
    expected_planes::Union{Nothing,Int}
    min_satellites_per_plane::Int
    verify_checksum::Bool
    warn_unbalanced_planes::Bool
    plane_count_warning_ratio::Float64

    function TLEOrbitPlaneGroupingConfig(;
        expected_planes::Union{Nothing,Int} = nothing,
        min_satellites_per_plane::Int = 1,
        verify_checksum::Bool = true,
        warn_unbalanced_planes::Bool = true,
        plane_count_warning_ratio::Real = 0.5,
    )
        expected_planes === nothing || expected_planes > 0 ||
            throw(ArgumentError("expected_planes must be positive when provided"))
        min_satellites_per_plane > 0 ||
            throw(ArgumentError("min_satellites_per_plane must be positive"))
        0 < plane_count_warning_ratio <= 1 ||
            throw(ArgumentError("plane_count_warning_ratio must be in (0, 1]"))
        return new(
            expected_planes,
            min_satellites_per_plane,
            verify_checksum,
            warn_unbalanced_planes,
            Float64(plane_count_warning_ratio),
        )
    end
end

"""
    TLEOrbitPlaneGroupingBuilder <: AbstractConstellationBuilder

基于 TLE 记录的升交点赤经（RAAN）自动分组轨道面的构建器。

# 字段
- `source::String`: 数据来源标识，固定为 `"tle-raan-grouping"`。
- `config::TLEOrbitPlaneGroupingConfig`: 自动分组配置。

# 说明
- 该构建器通过 Jenks 自然断点法对归一化后的 RAAN 进行聚类，从而把 TLE 记录组织成若干轨道面。
"""
struct TLEOrbitPlaneGroupingBuilder <: AbstractConstellationBuilder
    source::String
    config::TLEOrbitPlaneGroupingConfig
end

TLEOrbitPlaneGroupingBuilder(; config::TLEOrbitPlaneGroupingConfig = TLEOrbitPlaneGroupingConfig()) =
    TLEOrbitPlaneGroupingBuilder("tle-raan-grouping", config)

"""
    raan_span_deg(inclination_deg::Real)::Float64

根据轨道倾角返回默认 RAAN 展开范围（包装 `default_raan_span_deg`）。
"""
raan_span_deg(inclination_deg::Real)::Float64 = default_raan_span_deg(inclination_deg)

"""
    ParsedTLERecord

从单条 TLE 记录中解析出的关键轨道根数。

# 字段
- `record::TLERecordSpec`: 原始 TLE 规格（名称与两行 TLE 文本）。
- `inclination_deg::Float64`: 轨道倾角（度）。
- `raan_deg::Float64`: 升交点赤经（度），已归一化到 [0, 360)。
- `argument_of_perigee_deg::Float64`: 近地点幅角（度）。
- `mean_anomaly_deg::Float64`: 平均近点角（度）。
- `mean_motion_rev_per_day::Float64`: 每日绕地球圈数。
"""
struct ParsedTLERecord
    record::TLERecordSpec
    inclination_deg::Float64
    raan_deg::Float64
    argument_of_perigee_deg::Float64
    mean_anomaly_deg::Float64
    mean_motion_rev_per_day::Float64
end

"""
    parse_tle_record_elements(
        record::TLERecordSpec;
        verify_checksum::Bool = true,
    )::ParsedTLERecord

使用 SatelliteToolbox 解析单条 TLE 记录，提取后续分面与轨道计算所需的关键根数。

# 参数
- `record`: 原始 TLE 规格。
- `verify_checksum`: 是否校验 TLE 行校验和。

# 返回值
- 解析后的 `ParsedTLERecord`。

# 依赖
- 调用 `SatelliteToolbox.read_tle` 进行 TLE 解析。
"""
function parse_tle_record_elements(
    record::TLERecordSpec;
    verify_checksum::Bool = true,
)::ParsedTLERecord
    tle = SatelliteToolbox.read_tle(
        record.line1,
        record.line2;
        name = record.name,
        verify_checksum = verify_checksum,
    )
    return ParsedTLERecord(
        record,
        Float64(tle.inclination),
        mod(Float64(tle.raan), 360),
        Float64(tle.argument_of_perigee),
        Float64(tle.mean_anomaly),
        Float64(tle.mean_motion),
    )
end

"""
    circular_gap_rotation(values_deg::Vector{Float64})::Float64

在圆域 [0, 360) 上寻找最大间隙的“对侧端点”，作为旋转原点。

# 参数
- `values_deg`: 一组角度（度）。

# 返回值
- 最大间隙之后的角度值，用于将 RAAN 序列旋转到从 0 开始、避免在 0°/360° 处被截断。

# 说明
- 该函数主要用于 TLE 分面：当 RAAN 分布在 350° 到 10° 之间时，直接排序会产生伪大间隙；
  通过旋转原点可正确识别真实的轨道面间隔。
"""
# [算法说明]
# 圆域最大间隙旋转算法
# 用于在圆域 [0, 360) 上找到最大间隙的"对侧端点"，作为旋转原点。
#
# 问题背景：
#   RAAN 是角度值，在圆域上是循环的。例如 [350°, 355°, 5°, 10°] 这组数据，
#   线性排序后为 [5°, 10°, 350°, 355°]，在 10° 和 350° 之间会产生 340° 的伪间隙。
#   但实际上真实的大间隙在 355° 和 5° 之间（只有 10°）。
#
# 解决方案：
#   找到圆域上的最大间隙，将旋转原点设在最大间隙之后。
#   这样旋转后的真实间隙不会被 0°/360° 边界割裂。
#
# 算法步骤：
#   1. 将所有角度归一化到 [0, 360) 并排序
#   2. 计算相邻角度之间的间隙（使用模运算处理循环）
#   3. 最大间隙之后的角度值即为旋转原点
#   4. 将所有角度减去旋转原点并取模，得到旋转后的角度
function circular_gap_rotation(values_deg::Vector{Float64})::Float64
    isempty(values_deg) && throw(ArgumentError("values_deg must not be empty"))
    normalized = sort(mod.(values_deg, 360))
    length(normalized) == 1 && return normalized[1]

    best_origin = normalized[1]
    best_gap = -Inf
    for index in eachindex(normalized)
        # 在环形角度上计算当前值到下一个值的间隙
        next_index = index == lastindex(normalized) ? firstindex(normalized) : index + 1
        gap = mod(normalized[next_index] - normalized[index], 360)
        if gap > best_gap
            best_gap = gap
            best_origin = normalized[next_index]
        end
    end
    return best_origin
end

"""
    rotate_raan(raan_deg::Real, origin_deg::Real)::Float64

将 RAAN 按给定原点进行旋转，结果归一化到 [0, 360)。

# 参数
- `raan_deg`: 原始 RAAN（度）。
- `origin_deg`: 旋转原点（度）。
"""
rotate_raan(raan_deg::Real, origin_deg::Real)::Float64 = mod(Float64(raan_deg) - Float64(origin_deg), 360)

"""
    circular_mean_deg(values_deg::Vector{Float64})::Float64

计算一组角度的圆平均（circular mean）。

# 参数
- `values_deg`: 角度序列（度）。

# 返回值
- 平均角度（度），归一化到 [0, 360)。
"""
# [算法说明]
# 圆平均（Circular Mean）计算
# 角度值不能直接求算术平均，因为 359° 和 1° 的平均应该是 0°，而非 180°。
#
# 正确的圆平均算法：
#   1. 将每个角度转换为单位圆上的点：(cos(θ), sin(θ))
#   2. 对所有点的 x 和 y 分量分别求和
#   3. 用 atan2 求合成向量的角度
#   4. 归一化到 [0, 360)
#
# 数学公式：
#   mean_angle = atan2(Σsin(θ_i), Σcos(θ_i))
function circular_mean_deg(values_deg::Vector{Float64})::Float64
    isempty(values_deg) && throw(ArgumentError("values_deg must not be empty"))
    sin_sum = sum(sind(value) for value in values_deg)
    cos_sum = sum(cosd(value) for value in values_deg)
    return mod(rad2deg(atan(sin_sum, cos_sum)), 360)
end

"""
    cumulative_sums(values::Vector{Float64})

预计算前缀和与前缀平方和，用于加速 Jenks 自然断点法中的区间方差计算。

# 参数
- `values`: 已排序的数值序列。

# 返回值
- `(prefix, prefix_sq)`：长度均为 `length(values)+1` 的前缀和数组。
"""
function cumulative_sums(values::Vector{Float64})
    prefix = zeros(Float64, length(values) + 1)
    prefix_sq = zeros(Float64, length(values) + 1)
    for index in eachindex(values)
        prefix[index + 1] = prefix[index] + values[index]
        prefix_sq[index + 1] = prefix_sq[index] + values[index]^2
    end
    return prefix, prefix_sq
end

"""
    interval_sse(
        prefix::Vector{Float64},
        prefix_sq::Vector{Float64},
        start_index::Int,
        end_index::Int,
    )::Float64

利用前缀和计算某个区间内数值的组内离差平方和（SSE）。

# 参数
- `prefix`: 前缀和数组。
- `prefix_sq`: 前缀平方和数组。
- `start_index`: 区间起始索引（1-based，包含）。
- `end_index`: 区间结束索引（包含）。

# 返回值
- 该区间的 SSE，值越小表示区间内部越紧凑。
"""
# [算法说明]
# 区间内离差平方和（SSE）计算
# 使用前缀和优化，O(1) 时间复杂度计算任意区间的 SSE。
#
# 数学公式：
#   SSE = Σ(x_i - mean)² = Σx_i² - (Σx_i)² / n
#   利用前缀和可快速计算区间和与区间平方和：
#     Σx_i = prefix[end+1] - prefix[start]
#     Σx_i² = prefix_sq[end+1] - prefix_sq[start]
function interval_sse(prefix::Vector{Float64}, prefix_sq::Vector{Float64}, start_index::Int, end_index::Int)::Float64
    count = end_index - start_index + 1
    sum_value = prefix[end_index + 1] - prefix[start_index]
    sum_sq = prefix_sq[end_index + 1] - prefix_sq[start_index]
    return sum_sq - sum_value^2 / count
end

"""
    jenks_break_indices(values::Vector{Float64}, class_count::Int)::Vector{Int}

使用 Jenks 自然断点法（Fisher-Jenks）将有序数值分成 `class_count` 个类，并返回断点索引。

# 参数
- `values`: 待分组的数值向量。
- `class_count`: 期望类别数。

# 返回值
- 断点索引向量，长度等于 `class_count`，最后一个元素恒为 `length(values)`。

# 说明
- 本实现使用动态规划：先对输入排序，再计算所有可能区间的 SSE，
  通过 `costs` 与 `backtrack` 数组回溯最优断点。
- 用于 TLE 的 RAAN 聚类，使同一轨道面内的 RAAN 尽可能紧凑。
"""
# [算法说明]
# Jenks 自然断点法（Fisher-Jenks Algorithm）
# 一种基于动态规划的最优聚类算法，将有序数据分成若干类，
# 使得类内方差最小，类间方差最大。
#
# 算法原理：
#   对于有序数据 x_1 ≤ x_2 ≤ ... ≤ x_n，找到 k-1 个断点，
#   将数据分成 k 个类，使得总组内离差平方和（SSE）最小。
#
# 动态规划公式：
#   costs[j, k] = min over i: { costs[i-1, k-1] + SSE(i, j) }
#   其中 SSE(i, j) 是第 i 到第 j 个元素的组内离差平方和
#
# 时间复杂度：O(k * n²)，适合中等规模数据
#
# 应用场景：
#   用于 TLE 的 RAAN 聚类，将具有相似 RAAN 的卫星分到同一轨道面。
#   由于 RAAN 已排序，天然满足 Jenks 算法对输入有序的要求。
#
# 断点索引返回格式：
#   返回长度为 class_count 的向量，最后一个元素恒为 n
#   例如 n=10, class_count=3，返回 [3, 7, 10]
#   表示三个类：[1:3], [4:7], [8:10]
function jenks_break_indices(values::Vector{Float64}, class_count::Int)::Vector{Int}
    sorted_values = sort(values)
    n = length(sorted_values)
    1 <= class_count <= n || throw(ArgumentError("class_count must be in 1:length(values)"))
    class_count == 1 && return [n]

    # 预计算前缀和与前缀平方和，加速 SSE 计算
    prefix, prefix_sq = cumulative_sums(sorted_values)
    costs = fill(Inf, n, class_count)
    backtrack = fill(0, n, class_count)

    # 初始化：只有一类时，从第一个元素到第 end_index 个元素的 SSE
    for end_index in 1:n
        costs[end_index, 1] = interval_sse(prefix, prefix_sq, 1, end_index)
    end

    # 动态规划：逐层增加类别数，寻找最优前序断点
    for class_index in 2:class_count
        for end_index in class_index:n
            best_cost = Inf
            best_start = class_index
            for start_index in class_index:end_index
                # 总代价 = 前 k-1 类的最优代价 + 当前类的 SSE
                cost = costs[start_index - 1, class_index - 1] +
                       interval_sse(prefix, prefix_sq, start_index, end_index)
                if cost < best_cost
                    best_cost = cost
                    best_start = start_index
                end
            end
            costs[end_index, class_index] = best_cost
            backtrack[end_index, class_index] = best_start
        end
    end

    # 从最后一个类别反向回溯，得到断点索引
    breaks = Vector{Int}(undef, class_count)
    breaks[end] = n
    end_index = n
    for class_index in class_count:-1:2
        start_index = backtrack[end_index, class_index]
        breaks[class_index - 1] = start_index - 1
        end_index = start_index - 1
    end
    return breaks
end

"""
    infer_plane_count(
        rotated_raans::Vector{Float64},
        min_satellites_per_plane::Int,
    )::Int

根据归一化后的 RAAN 序列自动推断轨道面数量。

# 参数
- `rotated_raans`: 已旋转归一化的 RAAN 序列（度）。
- `min_satellites_per_plane`: 每面最少卫星数。

# 返回值
- 推断出的轨道面数量。

# 说明
- 通过相邻 RAAN 的间隙中位数识别“显著大间隙”，大间隙数加 1 即为面数；
  同时用 `min_satellites_per_plane` 约束面数上限，防止过度分割。
"""
# [算法说明]
# 轨道面数量自动推断算法
# 基于 RAAN 间隙分析确定轨道面数量。
#
# 核心思想：
#   同一轨道面的卫星 RAAN 几乎相同，不同轨道面之间有明显的 RAAN 间隙。
#   通过识别"显著大间隙"来确定轨道面边界。
#
# 算法步骤：
#   1. 对旋转后的 RAAN 排序，计算相邻间隙
#   2. 计算间隙的中位数（代表正常轨道面内的小间隙）
#   3. 定义显著大间隙阈值：max(3 × 中位数间隙, 0.5°)
#      - 3 倍因子：过滤掉正常的轨道面内差异
#      - 0.5° 下限：避免数值噪声导致的伪间隙
#   4. 统计显著大间隙的数量，大间隙数 + 1 = 轨道面数
#   5. 用 min_satellites_per_plane 约束面数上限，防止过度分割
#
# 例如：8 颗卫星的 RAAN 间隙为 [1.2°, 1.5°, 45°, 1.3°, 1.4°, 44°, 1.1°]
#   中位数间隙 ≈ 1.3°，阈值 = max(3.9°, 0.5°) = 3.9°
#   显著大间隙：45° 和 44°（共 2 个）
#   轨道面数 = 2 + 1 = 3
function infer_plane_count(rotated_raans::Vector{Float64}, min_satellites_per_plane::Int)::Int
    n = length(rotated_raans)
    n <= min_satellites_per_plane && return 1
    sorted_raans = sort(rotated_raans)
    gaps = diff(sorted_raans)
    isempty(gaps) && return 1

    median_gap = median(gaps)
    if median_gap == 0
        # 当中位数间隙为 0 时，使用正间隙的中位数避免除零
        positive_gaps = filter(>(0), gaps)
        isempty(positive_gaps) && return 1
        median_gap = median(positive_gaps)
    end

    # 显著大间隙：大于 3 倍中位数间隙，且至少 0.5°（避免数值噪声）
    threshold = max(3 * median_gap, 0.5)
    large_gaps = count(>(threshold), gaps)
    max_planes = max(1, fld(n, min_satellites_per_plane))
    return clamp(large_gaps + 1, 1, max_planes)
end

"""
    argument_of_latitude_deg(parsed::ParsedTLERecord)::Float64

计算 TLE 记录的升交角距（argument of latitude），即近地点幅角与平均近点角之和。

# 参数
- `parsed`: 已解析的 TLE 记录。
"""
argument_of_latitude_deg(parsed::ParsedTLERecord)::Float64 =
    mod(parsed.argument_of_perigee_deg + parsed.mean_anomaly_deg, 360)

"""
    warn_unbalanced_orbit_planes(
        shell_spec::TLEShellSpec,
        orbit_planes::Vector{OrbitPlane},
        config::TLEOrbitPlaneGroupingConfig,
    )

对轨道面卫星数量显著低于壳层平均值的情况发出警告。

# 参数
- `shell_spec`: 当前壳层规格。
- `orbit_planes`: 已生成的轨道面列表。
- `config`: 分组配置，控制是否警告及阈值比例。
"""
function warn_unbalanced_orbit_planes(
    shell_spec::TLEShellSpec,
    orbit_planes::Vector{OrbitPlane},
    config::TLEOrbitPlaneGroupingConfig,
)
    config.warn_unbalanced_planes || return nothing
    isempty(orbit_planes) && return nothing

    plane_counts = [satellite_count(plane) for plane in orbit_planes]
    average_count = mean(plane_counts)
    threshold = average_count * config.plane_count_warning_ratio
    for (plane, count) in zip(orbit_planes, plane_counts)
        if count < threshold
            @warn(
                "Orbit plane satellite count is below the shell average",
                shell_id = shell_spec.id,
                shell_name = shell_spec.name,
                orbit_plane_id = plane.id,
                satellite_count = count,
                average_satellite_count = average_count,
                warning_ratio = config.plane_count_warning_ratio,
            )
        end
    end
    return nothing
end

"""
    build_constellation(
        spec::ConstellationSpec,
        builder::DesignConstellationBuilder,
    )::Constellation

根据设计规格构建星座（调度到 design_orbit_generation.jl）。
"""
function build_constellation(spec::ConstellationSpec, builder::DesignConstellationBuilder)::Constellation
    return build_design_constellation(spec, builder)
end

"""
    build_constellation(
        spec::TLEConstellationSpec,
        builder::TLEConstellationBuilder,
    )::Constellation

根据 TLE 规格构建星座，每条 TLE 记录视为一个独立轨道面。

# 参数
- `spec`: TLE 星座规格。
- `builder`: TLE 构建器。

# 返回值
- 构造好的 `Constellation`，所有卫星的 `orbit_plane_id` 与 `plane_local_slot` 均设为 1，
  `shell_local_id` 按记录顺序递增。
"""
function build_constellation(spec::TLEConstellationSpec, builder::TLEConstellationBuilder)::Constellation
    shells = Shell[]
    global_satellite_id = 1
    metadata = SourceMetadata(builder.source)

    for shell_spec in spec.shells
        satellites = Satellite[]

        for (record_index, record) in pairs(shell_spec.records)
            orbit_elements = TLEOrbitElementSet(
                record.name,
                record.line1,
                record.line2;
                metadata = metadata,
            )

            push!(
                satellites,
                Satellite(
                    identifier = SatelliteId(
                        global_id = global_satellite_id,
                        shell_id = shell_spec.id,
                        shell_local_id = record_index,
                        orbit_plane_id = 1,
                        plane_local_slot = record_index,
                    ),
                    name = record.name,
                    orbit_elements = orbit_elements,
                ),
            )
            global_satellite_id += 1
        end

        orbit_plane = OrbitPlane(1, shell_spec.id, 0.0, satellites)
        push!(
            shells,
            Shell(
                id = shell_spec.id,
                name = shell_spec.name,
                orbit_planes = [orbit_plane],
            ),
        )
    end

    return Constellation(spec.name, shells, SourceMetadata(spec.source))
end

"""
    build_constellation(
        spec::TLEConstellationSpec,
        builder::TLEOrbitPlaneGroupingBuilder,
    )::Constellation

根据 TLE 规格构建星座，并按 RAAN 自动分组为轨道面。

# 参数
- `spec`: TLE 星座规格。
- `builder`: TLE 自动分面构建器，携带分组配置。

# 返回值
- 构造好的 `Constellation`，其中 TLE 记录按 RAAN 聚类到不同 `OrbitPlane`，
  面内卫星按升交角距排序。

# 依赖
- 调用 `parse_tle_record_elements` 解析 TLE。
- 调用 `build_grouped_tle_orbit_planes` 进行 RAAN 分组与面内排序。
"""
function build_constellation(spec::TLEConstellationSpec, builder::TLEOrbitPlaneGroupingBuilder)::Constellation
    shells = Shell[]
    global_satellite_id = 1
    metadata = SourceMetadata(builder.source)

    for shell_spec in spec.shells
        parsed_records = [
            parse_tle_record_elements(record; verify_checksum = builder.config.verify_checksum)
            for record in shell_spec.records
        ]
        orbit_planes, global_satellite_id = build_grouped_tle_orbit_planes(
            shell_spec,
            parsed_records,
            metadata,
            builder.config,
            global_satellite_id,
        )

        shell_inclination = isempty(parsed_records) ? nothing :
                            mean(record.inclination_deg for record in parsed_records)
        push!(
            shells,
            Shell(
                id = shell_spec.id,
                name = shell_spec.name,
                inclination_deg = shell_inclination,
                orbit_planes = orbit_planes,
            ),
        )
    end

    return Constellation(spec.name, shells, SourceMetadata(spec.source))
end

"""
    build_grouped_tle_orbit_planes(
        shell_spec::TLEShellSpec,
        parsed_records::Vector{ParsedTLERecord},
        metadata::SourceMetadata,
        config::TLEOrbitPlaneGroupingConfig,
        next_global_satellite_id::Int,
    )

将已解析的 TLE 记录按 RAAN 分组为轨道面。

# 参数
- `shell_spec`: 当前壳层规格。
- `parsed_records`: 已解析的 TLE 记录列表。
- `metadata`: 来源元数据，用于构造轨道元素。
- `config`: 自动分组配置。
- `next_global_satellite_id`: 下一个可用的全局卫星 ID。

# 返回值
- `(orbit_planes, global_satellite_id)`：轨道面列表与更新后的下一个全局卫星 ID。

# 流程
1. 通过 `circular_gap_rotation` 选择旋转原点，避免 0°/360° 截断。
2. 对旋转后的 RAAN 排序，使用 Jenks 自然断点法或固定面数进行分组。
3. 每个面内按升交角距排序，计算面内 RAAN 圆平均。
4. 按平均 RAAN 对面排序，分配 `SatelliteId` 分层索引。
"""
# [算法说明]
# TLE 自动分轨道面构建算法
# 将已解析的 TLE 记录按 RAAN 自动分组为轨道面。
#
# 四步流程：
#   步骤 1：圆域旋转
#     选择旋转原点，使真实大间隙不被 0°/360° 边界割裂
#
#   步骤 2：Jenks 聚类
#     确定轨道面数量（自动推断或用户指定）
#     使用 Jenks 自然断点法计算最优断点
#
#   步骤 3：面内排序
#     每个面内按升交角距排序（确保面内卫星按轨道位置排列）
#     计算面平均 RAAN（用于轨道面排序和后续拓扑构建）
#
#   步骤 4：ID 分配
#     按平均 RAAN 对面排序（保证轨道面 ID 与 RAAN 单调对应）
#     分配分层 SatelliteId（global_id, shell_id, orbit_plane_id, plane_local_slot）
#
# 分层 ID 的作用：
#   - global_id：全局唯一标识，用于路由和邻接表
#   - orbit_plane_id + plane_local_slot：用于拓扑构建中的面内/面间连接
#   - shell_id + shell_local_id：用于壳层级别的管理
function build_grouped_tle_orbit_planes(
    shell_spec::TLEShellSpec,
    parsed_records::Vector{ParsedTLERecord},
    metadata::SourceMetadata,
    config::TLEOrbitPlaneGroupingConfig,
    next_global_satellite_id::Int,
)
    # 步骤 1：选择旋转原点，使真实大间隙不被 0°/360° 边界割裂
    raan_origin = circular_gap_rotation([record.raan_deg for record in parsed_records])
    grouped_records = [
        (record = record, rotated_raan = rotate_raan(record.raan_deg, raan_origin))
        for record in parsed_records
    ]
    sort!(grouped_records; by = item -> item.rotated_raan)

    # 步骤 2：确定轨道面数量并计算 Jenks 断点
    plane_count = config.expected_planes === nothing ?
                  infer_plane_count(
                      [item.rotated_raan for item in grouped_records],
                      config.min_satellites_per_plane,
                  ) :
                  min(config.expected_planes, length(grouped_records))
    break_indices = jenks_break_indices(
        [item.rotated_raan for item in grouped_records],
        plane_count,
    )

    shell_local_satellite_id = 1
    start_index = 1
    global_satellite_id = next_global_satellite_id
    plane_groups = Vector{Tuple{Float64,Vector{ParsedTLERecord}}}()

    # 步骤 3：按断点划分记录，面内按升交角距排序，计算面平均 RAAN
    for end_index in break_indices
        plane_records = [item.record for item in grouped_records[start_index:end_index]]
        # 面内按升交角距排序：确保卫星按轨道位置顺序排列
        sort!(plane_records; by = argument_of_latitude_deg)
        # 计算面平均 RAAN（使用圆平均避免 0°/360° 问题）
        mean_raan = isempty(plane_records) ? 0.0 :
                    circular_mean_deg([record.raan_deg for record in plane_records])
        push!(plane_groups, (mean_raan, plane_records))
        start_index = end_index + 1
    end
    # 按平均 RAAN 对面排序，保证轨道面 ID 与 RAAN 单调对应
    sort!(plane_groups; by = first)

    # 步骤 4：构造轨道面与卫星，分配全局/壳层/面内分层 ID
    orbit_planes = OrbitPlane[]
    for (plane_index, (mean_raan, plane_records)) in pairs(plane_groups)
        plane_satellites = Satellite[]
        for (slot_index, parsed) in pairs(plane_records)
            orbit_elements = TLEOrbitElementSet(
                parsed.record.name,
                parsed.record.line1,
                parsed.record.line2;
                metadata = metadata,
            )
            push!(
                plane_satellites,
                Satellite(
                    identifier = SatelliteId(
                        global_id = global_satellite_id,
                        shell_id = shell_spec.id,
                        shell_local_id = shell_local_satellite_id,
                        orbit_plane_id = plane_index,
                        plane_local_slot = slot_index,
                    ),
                    name = parsed.record.name,
                    orbit_elements = orbit_elements,
                ),
            )
            global_satellite_id += 1
            shell_local_satellite_id += 1
        end

        push!(orbit_planes, OrbitPlane(plane_index, shell_spec.id, mean_raan, plane_satellites))
    end
    warn_unbalanced_orbit_planes(shell_spec, orbit_planes, config)

    return orbit_planes, global_satellite_id
end

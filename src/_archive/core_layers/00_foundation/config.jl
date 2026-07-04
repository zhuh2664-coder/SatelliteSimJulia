"""
    共享层：星座设计规格与 TLE 输入配置模块

本文件定义两类星座输入规格：
1. 设计规格（ShellSpec / ConstellationSpec）：由 TOML 设计文件生成的规则星座；
2. 真实 TLE 规格（TLERecordSpec / TLEShellSpec / TLEConstellationSpec）：由两行根数构建。

这些规格是 core/orbit_layer 传播器与 core/network_layer/builders.jl 构造
Constellation 的输入，处于项目流水线最上游。

# 星座设计参数体系
#
# 星座设计遵循"星座 → 壳层 → 轨道面 → 卫星"的层次结构：
#
#   ConstellationSpec（星座）
#   ├── name: 星座名称（如 "Starlink", "OneWeb"）
#   ├── source: 数据来源
#   └── shells: [ShellSpec, ...]（壳层列表）
#       ├── ShellSpec（壳层 1）
#       │   ├── altitude_km: 轨道高度（决定轨道周期）
#       │   ├── inclination_deg: 轨道倾角（决定覆盖纬度）
#       │   ├── orbit_count: 轨道面数量（决定经度覆盖）
#       │   ├── satellites_per_orbit: 每轨卫星数（决定相位覆盖）
#       │   └── phase_shift: 相位偏移（优化覆盖均匀性）
#       └── ShellSpec（壳层 2）
#           └── ...
#
# 关键参数的物理含义：
#   - altitude_km：决定轨道周期 T = 2π√(a³/μ)，a = R_Earth + altitude
#     例如 550 km → T ≈ 96 分钟
#   - inclination_deg：决定卫星能覆盖的最大纬度
#     例如 53° → 最高覆盖纬度约 53°（忽略摄动）
#   - orbit_count × satellites_per_orbit：总卫星数
#     例如 72 面 × 22 星 = 1584 星/壳层
#   - phase_shift：相邻轨道面的相位偏移，优化全球覆盖均匀性
#     典型值为 0 或 1（即相邻面卫星错开半个间距）"""

using TOML

"""
    validate_shell_spec_inputs(; ...)

校验壳层（shell）设计参数的合法性。

# 参数
- `id::Int`: 壳层 ID，必须为正
- `name::String`: 壳层名称，非空
- `altitude_km::Real`: 轨道高度（km），必须为正
- `orbit_cycle_s::Union{Nothing,Int}`: 轨道周期（秒），提供时必须为正
- `inclination_deg::Real`: 轨道倾角（度），必须在 `[0, 180]`
- `phase_shift::Int`: 相邻轨道面相位偏移，非负
- `orbit_count::Int`: 轨道面数量，正
- `satellites_per_orbit::Int`: 每轨卫星数，正

# 返回
- `Nothing`

# 异常
- 任一条件不满足时抛出 `ArgumentError`。
"""
function validate_shell_spec_inputs(;
    id::Int,
    name::String,
    altitude_km::Real,
    orbit_cycle_s::Union{Nothing,Int},
    inclination_deg::Real,
    phase_shift::Int,
    orbit_count::Int,
    satellites_per_orbit::Int,
)::Nothing
    id > 0 || throw(ArgumentError("shell id must be positive"))
    !isempty(name) || throw(ArgumentError("shell name must not be empty"))
    altitude_km > 0 || throw(ArgumentError("altitude_km must be positive"))
    orbit_cycle_s === nothing || orbit_cycle_s > 0 ||
        throw(ArgumentError("orbit_cycle_s must be positive when provided"))
    0 <= inclination_deg <= 180 || throw(ArgumentError("inclination_deg must be in [0, 180]"))
    phase_shift >= 0 || throw(ArgumentError("phase_shift must be non-negative"))
    orbit_count > 0 || throw(ArgumentError("orbit_count must be positive"))
    satellites_per_orbit > 0 || throw(ArgumentError("satellites_per_orbit must be positive"))
    return nothing
end

"""
    validate_design_shell_inputs(; kwargs...)

`validate_shell_spec_inputs` 的别名，用于设计规格入口保持语义一致。
"""
validate_design_shell_inputs(; kwargs...) = validate_shell_spec_inputs(; kwargs...)

"""
    ShellSpec

设计星座中单个壳层（shell）的规格。

# 壳层参数设计原则
#
# 1. altitude_km（轨道高度）：
#    - 低轨（LEO）：200-2000 km，低延迟（~10 ms），但覆盖面积小
#    - 中轨（MEO）：2000-35786 km，中等延迟
#    - 高轨（GEO）：35786 km，高延迟（~240 ms），但覆盖面积大
#    - Starlink 典型高度：550 km（低延迟）和 1150 km（覆盖补充）
#
# 2. inclination_deg（轨道倾角）：
#    - 0°：赤道轨道，覆盖赤道区域
#    - 53°：中倾角，覆盖中纬度人口密集区
#    - 90°：极地轨道，覆盖全球（包括极地）
#    - 多壳层星座通常混合不同倾角以优化全球覆盖
#
# 3. orbit_count × satellites_per_orbit（卫星密度）：
#    - 轨道面数量决定经度方向的覆盖密度
#    - 每轨卫星数决定纬度方向的覆盖密度
#    - 总卫星数 = orbit_count × satellites_per_orbit
#    - 更多卫星 → 更好的覆盖和容量，但成本更高
#
# 4. phase_shift（相位偏移）：
#    - 相邻轨道面的卫星相位偏移量
#    - 值为 k 表示：第 i 面的第 j 颗星与第 i+1 面的第 j+k 颗星对齐
#    - 优化目标：最小化覆盖重叠，最大化全球均匀覆盖

# 字段
- `id::Int`: 壳层唯一标识
- `name::String`: 壳层名称
- `altitude_km::Float64`: 轨道高度（km）
- `orbit_cycle_s::Union{Nothing,Int}`: 轨道周期（秒），可选
- `inclination_deg::Float64`: 轨道倾角（度）
- `phase_shift::Int`: 相邻轨道面相位偏移
- `orbit_count::Int`: 轨道面数量
- `satellites_per_orbit::Int`: 每个轨道面的卫星数量
"""
struct ShellSpec
    id::Int
    name::String
    altitude_km::Float64
    orbit_cycle_s::Union{Nothing,Int}
    inclination_deg::Float64
    phase_shift::Int
    orbit_count::Int
    satellites_per_orbit::Int

    """
        ShellSpec(; ...)

    构造 `ShellSpec` 并在创建时调用 `validate_shell_spec_inputs` 完成参数校验。
    """
    function ShellSpec(;
        id::Int,
        name::String,
        altitude_km::Real,
        orbit_cycle_s::Union{Nothing,Int} = nothing,
        inclination_deg::Real,
        phase_shift::Int,
        orbit_count::Int,
        satellites_per_orbit::Int,
    )
        validate_shell_spec_inputs(
            id = id,
            name = name,
            altitude_km = altitude_km,
            orbit_cycle_s = orbit_cycle_s,
            inclination_deg = inclination_deg,
            phase_shift = phase_shift,
            orbit_count = orbit_count,
            satellites_per_orbit = satellites_per_orbit,
        )
        return new(
            id,
            name,
            Float64(altitude_km),
            orbit_cycle_s,
            Float64(inclination_deg),
            phase_shift,
            orbit_count,
            satellites_per_orbit,
        )
    end
end

"""
    design_shell_input(; ...)

`ShellSpec` 的工厂函数，返回一个经过校验的壳层规格对象。
"""
function design_shell_input(;
    id::Int,
    name::String,
    altitude_km::Real,
    orbit_cycle_s::Union{Nothing,Int} = nothing,
    inclination_deg::Real,
    phase_shift::Int,
    orbit_count::Int,
    satellites_per_orbit::Int,
)
    return ShellSpec(
        id = id,
        name = name,
        altitude_km = altitude_km,
        orbit_cycle_s = orbit_cycle_s,
        inclination_deg = inclination_deg,
        phase_shift = phase_shift,
        orbit_count = orbit_count,
        satellites_per_orbit = satellites_per_orbit,
    )
end

"""
    ConstellationSpec

设计星座规格：包含星座名称、来源与若干壳层规格。

# 星座规格设计
#
# ConstellationSpec 是星座设计的顶层输入，包含：
#   1. name：星座标识（如 "Starlink"、"OneWeb"、"Kuiper"）
#   2. source：数据来源（如 "SpaceX FCC filing"、"design specification"）
#   3. shells：壳层规格列表，按高度分组
#
# 多壳层设计的目的：
#   - 不同高度壳层提供不同的覆盖和容量特性
#   - 低轨壳层：低延迟，服务实时应用
#   - 高轨壳层：广覆盖，服务偏远地区
#   - 混合设计平衡延迟、容量和覆盖
#
# 典型多壳层星座示例（Starlink）：
#   壳层 1：550 km, 53°, 72 面 × 22 星 = 1584 星（主力壳层）
#   壳层 2：1150 km, 53°, 72 面 × 22 星 = 1584 星（覆盖补充）
#   壳层 3：1150 km, 75°, 36 面 × 20 星 = 720 星（高纬度覆盖）

# 字段
- `name::String`: 星座名称
- `source::String`: 数据来源描述
- `shells::Vector{ShellSpec}`: 壳层规格列表
"""
struct ConstellationSpec
    name::String
    source::String
    shells::Vector{ShellSpec}

    """
        ConstellationSpec(name::String, source::String, shells::Vector{ShellSpec})

    直接构造设计星座规格，校验名称非空、壳层非空且 ID 唯一。
    """
    function ConstellationSpec(name::String, source::String, shells::Vector{ShellSpec})
        !isempty(name) || throw(ArgumentError("constellation name must not be empty"))
        !isempty(shells) || throw(ArgumentError("constellation must contain at least one shell"))
        ids = [shell.id for shell in shells]
        length(ids) == length(unique(ids)) || throw(ArgumentError("shell ids must be unique"))
        return new(name, source, shells)
    end
end

"""
    ConstellationSpec(name::String, source::String, shells::Vector)

将任意可转换为 `ShellSpec` 的元素列表提升为 `Vector{ShellSpec}` 后再构造。
"""
function ConstellationSpec(name::String, source::String, shells::Vector)
    shell_specs = ShellSpec[shell for shell in shells]
    return ConstellationSpec(name, source, shell_specs)
end

"""
    TLERecordSpec

单个卫星的两行轨道根数（TLE）记录。

# TLE 记录结构
#
# TLE（Two-Line Element）是北美防空司令部（NORAD）发布的标准轨道数据格式。
# 每条记录包含三部分：
#   1. name：卫星名称（如 "STARLINK-1007"）
#   2. line1：第一行，包含：
#      - 分类号（国际编号）
#      - 发射年份
#      - 轨道周期（rev/day）
#      - 倾角（deg）
#      - 升交点赤经（deg）
#      - 偏心率
#   3. line2：第二行，包含：
#      - 近地点幅角（deg）
#      - 平近点角（deg）
#      - 平均运动（rev/day）
#      - 轨道圈数
#      - 修订号
#
# TLE 的局限性：
#   1. 时效性：TLE 数据有有效期，通常几天到几周
#   2. 精度：近地轨道约 1 km，深空轨道约 10 km
#   3. 无速度信息：需要通过 SGP4 传播器推算
#   4. 不包含姿态信息：仅有轨道位置

# 字段
- `name::String`: 卫星名称
- `line1::String`: TLE 第一行
- `line2::String`: TLE 第二行
"""
struct TLERecordSpec
    name::String
    line1::String
    line2::String

    """
        TLERecordSpec(name::AbstractString, line1::AbstractString, line2::AbstractString)

    构造 TLE 记录，校验名称非空且两行分别以 `"1 "` / `"2 "` 开头。
    """
    function TLERecordSpec(name::AbstractString, line1::AbstractString, line2::AbstractString)
        !isempty(strip(name)) || throw(ArgumentError("TLE name must not be empty"))
        startswith(strip(line1), "1 ") || throw(ArgumentError("TLE line1 must start with \"1 \""))
        startswith(strip(line2), "2 ") || throw(ArgumentError("TLE line2 must start with \"2 \""))
        return new(String(strip(name)), String(strip(line1)), String(strip(line2)))
    end
end

"""
    TLEShellSpec

由真实 TLE 记录组成的壳层规格。

# TLE 壳层组织
#
# TLEShellSpec 将多条 TLE 记录组织为一个逻辑壳层。
# 与设计规格不同，TLE 壳层没有明确的轨道面划分——
# 卫星的轨道参数由各自的 TLE 数据决定，可能不完全均匀分布。
#
# 典型用法：
#   - 将同一发射批次的卫星归为一个 TLE 壳层
#   - 将同一运营商的卫星归为一个 TLE 壳层
#   - 按轨道高度范围分组（如 500-600 km 一个壳层）
#
# 与 ShellSpec 的区别：
#   - ShellSpec：规则设计，卫星均匀分布，参数可解析
#   - TLEShellSpec：真实数据，卫星分布可能不均匀，需要传播器计算
#
# 为什么需要 TLE 壳层：
#   1. 真实仿真：使用实际发射的卫星数据，而非理想化设计
#   2. 覆盖验证：验证设计星座的实际覆盖性能
#   3. 攻击分析：评估对真实星座的攻击效果

# 字段
- `id::Int`: 壳层 ID
- `name::String`: 壳层名称
- `records::Vector{TLERecordSpec}`: 该壳层包含的 TLE 记录
"""
struct TLEShellSpec
    id::Int
    name::String
    records::Vector{TLERecordSpec}

    """
        TLEShellSpec(; id::Int, name::String, records::Vector{TLERecordSpec})

    构造 TLE 壳层规格，校验 ID 为正、名称非空且至少含一条记录。
    """
    function TLEShellSpec(; id::Int, name::String, records::Vector{TLERecordSpec})
        id > 0 || throw(ArgumentError("TLE shell id must be positive"))
        !isempty(strip(name)) || throw(ArgumentError("TLE shell name must not be empty"))
        !isempty(records) || throw(ArgumentError("TLE shell must contain at least one record"))
        return new(id, strip(name), records)
    end
end

"""
    TLEConstellationSpec

基于真实 TLE 数据的完整星座规格。

# 字段
- `name::String`: 星座名称
- `source::String`: 数据来源
- `shells::Vector{TLEShellSpec}`: TLE 壳层列表
"""
struct TLEConstellationSpec
    name::String
    source::String
    shells::Vector{TLEShellSpec}

    """
        TLEConstellationSpec(name::String, source::String, shells::Vector{TLEShellSpec})

    直接构造 TLE 星座规格，校验名称非空、壳层非空且壳层 ID 唯一。
    """
    function TLEConstellationSpec(name::String, source::String, shells::Vector{TLEShellSpec})
        !isempty(strip(name)) || throw(ArgumentError("TLE constellation name must not be empty"))
        !isempty(shells) || throw(ArgumentError("TLE constellation must contain at least one shell"))
        ids = [shell.id for shell in shells]
        length(ids) == length(unique(ids)) || throw(ArgumentError("TLE shell ids must be unique"))
        return new(strip(name), strip(source), shells)
    end
end

"""
    load_constellation_spec(path::AbstractString)::ConstellationSpec

从 TOML 文件加载设计星座规格。

# TOML 文件格式
#
# TOML 文件结构示例：
#   [constellation]
#   name = "Starlink"
#   source = "SpaceX FCC filing"
#
#   [[shells]]
#   id = 1
#   name = "shell_550km"
#   altitude_km = 550
#   inclination_deg = 53
#   orbit_count = 72
#   satellites_per_orbit = 22
#   phase_shift = 0
#
#   [[shells]]
#   id = 2
#   name = "shell_1150km"
#   altitude_km = 1150
#   ...
#
# 解析流程：
#   1. TOML.parsefile 读取文件为嵌套字典
#   2. 提取 [constellation] 表获取名称和来源
#   3. 遍历 [[shells]] 数组，逐条构造 ShellSpec
#   4. 缺失字段使用默认值（id=序号, phase_shift=0）
#   5. 汇总为 ConstellationSpec

# 参数
- `path::AbstractString`: TOML 文件路径

# 返回
- `ConstellationSpec`: 解析后的设计星座规格
"""
function load_constellation_spec(path::AbstractString)::ConstellationSpec
    raw = TOML.parsefile(path)
    constellation = raw["constellation"]
    shell_tables = raw["shells"]

    shells = ShellSpec[]
    # 按顺序解析 TOML 中的每个 shell 条目，缺失字段使用合理默认值
    for (index, shell) in enumerate(shell_tables)
        push!(
            shells,
            ShellSpec(
                id = Int(get(shell, "id", index)),
                name = String(shell["name"]),
                altitude_km = shell["altitude_km"],
                orbit_cycle_s = haskey(shell, "orbit_cycle_s") ? Int(shell["orbit_cycle_s"]) : nothing,
                inclination_deg = shell["inclination_deg"],
                phase_shift = Int(get(shell, "phase_shift", 0)),
                orbit_count = Int(shell["orbit_count"]),
                satellites_per_orbit = Int(shell["satellites_per_orbit"]),
            ),
        )
    end

    return ConstellationSpec(
        String(constellation["name"]),
        String(get(constellation, "source", "unknown")),
        shells,
    )
end

"""
    parse_tle_records(tles::AbstractString; default_name_prefix::String = "SAT")::Vector{TLERecordSpec}

从一段 TLE 文本中解析出所有卫星记录。

# TLE 文本解析算法
#
# TLE 文本有三种常见格式：
#
# 格式 1：命名 TLE（标准格式）
#   卫星名称
#   1 25544U 98067A   23123.45678900  .00001234  00000+0  12345-6  0  9999
#   2 25544  51.6400 234.5678 0001234  45.6789 314.3210 15.49581234123456
#
# 格式 2：匿名 TLE（以 line1 开头）
#   1 25544U 98067A   23123.45678900  .00001234  00000+0  12345-6  0  9999
#   2 25544  51.6400 234.5678 0001234  45.6789 314.3210 15.49581234123456
#
# 格式 3：混合格式（注释行以 # 开头，空行跳过）
#
# 解析状态机：
#   state = START
#   for line in lines:
#     if line starts with "1 ":
#       # 匿名 TLE：当前行为 line1
#       state = LINE1_READ
#       current_line1 = line
#     elif state == LINE1_READ:
#       # 匿名 TLE：当前行为 line2
#       push(records, TLERecordSpec(name, current_line1, line))
#       state = START
#     else:
#       # 命名 TLE：当前行为名称
#       current_name = line
#       state = NAME_READ
#   注意：命名 TLE 需要连续三行（name, line1, line2）

# 参数
- `tles::AbstractString`: 包含 TLE 的原始文本
- `default_name_prefix::String`: 匿名记录名称前缀

# 返回
- `Vector{TLERecordSpec}`: 解析出的 TLE 记录列表
"""
function parse_tle_records(tles::AbstractString; default_name_prefix::String = "SAT")::Vector{TLERecordSpec}
    # 过滤空行与以 '#' 开头的注释行，并对每行去除首尾空白
    lines = [
        strip(line) for line in split(tles, '\n')
        if !isempty(strip(line)) && !startswith(strip(line), "#")
    ]
    records = TLERecordSpec[]
    index = 1
    unnamed_count = 1

    # 按 TLE 文本的三种行模式循环解析
    while index <= length(lines)
        line = lines[index]
        if startswith(line, "1 ")
            # 匿名 TLE：当前行为 line1，下一行为 line2
            index + 1 <= length(lines) || throw(ArgumentError("TLE line1 missing line2"))
            push!(records, TLERecordSpec("$(default_name_prefix)-$(unnamed_count)", line, lines[index + 1]))
            unnamed_count += 1
            index += 2
        else
            # 命名 TLE：当前行为名称，随后两行分别为 line1、line2
            index + 2 <= length(lines) || throw(ArgumentError("TLE name missing line1/line2"))
            push!(records, TLERecordSpec(line, lines[index + 1], lines[index + 2]))
            index += 3
        end
    end

    !isempty(records) || throw(ArgumentError("no TLE records found"))
    return records
end

"""
    load_tle_records(path::AbstractString; default_name_prefix::String = "SAT")::Vector{TLERecordSpec}

从文件读取 TLE 文本并解析为记录列表。

# 参数
- `path::AbstractString`: TLE 文件路径
- `default_name_prefix::String`: 匿名记录名称前缀

# 返回
- `Vector{TLERecordSpec}`: 解析出的 TLE 记录列表

# 依赖
- 调用 `parse_tle_records` 进行实际解析。
"""
function load_tle_records(path::AbstractString; default_name_prefix::String = "SAT")::Vector{TLERecordSpec}
    return parse_tle_records(read(path, String); default_name_prefix = default_name_prefix)
end

"""
    TLEConstellationSpec(
        name::String,
        source::String,
        records::Vector{TLERecordSpec};
        shell_id::Int = 1,
        shell_name::String = "shell1",
    )::TLEConstellationSpec

将所有 TLE 记录封装为仅含一个壳层的 `TLEConstellationSpec`。

# 参数
- `name::String`: 星座名称
- `source::String`: 数据来源
- `records::Vector{TLERecordSpec}`: TLE 记录列表
- `shell_id::Int`: 壳层 ID，默认为 1
- `shell_name::String`: 壳层名称，默认为 `"shell1"`

# 返回
- `TLEConstellationSpec`: 封装后的星座规格

# 依赖
- 调用 `TLEShellSpec` 与 `TLEConstellationSpec` 主构造函数。
"""
function TLEConstellationSpec(
    name::String,
    source::String,
    records::Vector{TLERecordSpec};
    shell_id::Int = 1,
    shell_name::String = "shell1",
)::TLEConstellationSpec
    return TLEConstellationSpec(
        name,
        source,
        [TLEShellSpec(id = shell_id, name = shell_name, records = records)],
    )
end

"""
    load_tle_constellation_spec(
        path::AbstractString;
        name::String,
        source::String = path,
        shell_id::Int = 1,
        shell_name::String = "shell1",
        default_name_prefix::String = "SAT",
    )::TLEConstellationSpec

从 TLE 文件直接加载为 `TLEConstellationSpec`。

# 参数
- `path::AbstractString`: TLE 文件路径
- `name::String`: 星座名称
- `source::String`: 数据来源，默认为文件路径
- `shell_id::Int`: 壳层 ID，默认为 1
- `shell_name::String`: 壳层名称，默认为 `"shell1"`
- `default_name_prefix::String`: 匿名记录名称前缀

# 返回
- `TLEConstellationSpec`: 加载的星座规格

# 依赖
- 调用 `load_tle_records` 解析文件；
- 调用 `TLEConstellationSpec` 单壳层构造函数封装结果。
"""
function load_tle_constellation_spec(
    path::AbstractString;
    name::String,
    source::String = path,
    shell_id::Int = 1,
    shell_name::String = "shell1",
    default_name_prefix::String = "SAT",
)::TLEConstellationSpec
    records = load_tle_records(path; default_name_prefix = default_name_prefix)
    return TLEConstellationSpec(name, source, records; shell_id = shell_id, shell_name = shell_name)
end

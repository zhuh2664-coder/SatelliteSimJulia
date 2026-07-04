# TLE 数据源管理模块。
#
# 本文件负责统一加载不同来源的 TLE（Two-Line Element）数据：
#   - 本地三行 TLE 文本文件。
#   - StarPerf 导出的 JSON 格式 TLE 记录。
#
# 它提供了一套可扩展的 `AbstractTLESource` 接口和 `TLESourceRegistry` 注册表，
# 使得星座构建器可以用统一的 `load_tle_records(registry, id)` 获取 `TLERecordSpec` 列表，
# 再进一步生成 `TLEOrbitElementSet` 与 `Satellite`。
#
# 依赖：
#   - SatelliteToolbox：TLE 解析、校验与构造。
#   - Dates、JSON：StarPerf JSON 的日期解析与文件读取。
#   - TLERecordSpec 由外部模块定义（通常为 network_layer/builders.jl 或相关 spec 模块）。
#   - `load_tle_records(path; default_name_prefix)` 由外部 TLE 文本解析模块提供。

using Dates
using JSON
import SatelliteToolbox

# TLE 记录结构（在核心层内部定义）
"""
    TLERecordSpec

单条 TLE 记录的规范结构。
"""
struct TLERecordSpec
    name::String
    line1::String
    line2::String
end

# export AbstractTLESource, TLETextFileSource, TLEJsonFileSource, TLESourceRegistry, TLERecordSpec  # 收窄：无下游消费者
# export tle_source_id, load_tle_records, register_tle_source, get_tle_source

"""
    AbstractTLESource

TLE 数据源的抽象基类型。

所有具体数据源（文本文件、JSON 等）都应继承此类型，并实现 `tle_source_id` 与
`load_tle_records(source)` 方法，以便被 `TLESourceRegistry` 统一管理和加载。
"""
abstract type AbstractTLESource end

"""
    TLETextFileSource <: AbstractTLESource

本地三行 TLE 文本文件数据源。

# 字段
- `id::String`：数据源在注册表中的唯一标识。
- `path::String`：TLE 文本文件路径。
- `default_name_prefix::String`：当 TLE 记录缺少名称时，用于生成默认卫星名称的前缀。
- `verify_with_juliaspace::Bool`：加载后是否用 SatelliteToolbox 再次校验每条记录。
"""
struct TLETextFileSource <: AbstractTLESource
    id::String
    path::String
    default_name_prefix::String
    verify_with_juliaspace::Bool

    function TLETextFileSource(
        id::AbstractString,
        path::AbstractString;
        default_name_prefix::AbstractString = "SAT",
        verify_with_juliaspace::Bool = true,
    )
        !isempty(strip(id)) || throw(ArgumentError("TLE source id must not be empty"))
        !isempty(strip(path)) || throw(ArgumentError("TLE source path must not be empty"))
        !isempty(strip(default_name_prefix)) ||
            throw(ArgumentError("default_name_prefix must not be empty"))
        return new(String(strip(id)), String(path), String(strip(default_name_prefix)), verify_with_juliaspace)
    end
end

"""
    StarPerfTLEJsonSource <: AbstractTLESource

StarPerf 平台导出的 JSON 格式 TLE 数据源。

# 字段
- `id::String`：数据源在注册表中的唯一标识。
- `path::String`：StarPerf JSON 文件路径。
- `verify_with_juliaspace::Bool`：加载后是否用 SatelliteToolbox 校验生成的 TLE 行。

# 说明
StarPerf JSON 通常把 TLE 的各个字段以键值对形式存储，本类型负责将其转换为标准 TLE 三行记录。
"""
struct StarPerfTLEJsonSource <: AbstractTLESource
    id::String
    path::String
    verify_with_juliaspace::Bool

    function StarPerfTLEJsonSource(
        id::AbstractString,
        path::AbstractString;
        verify_with_juliaspace::Bool = true,
    )
        !isempty(strip(id)) || throw(ArgumentError("TLE source id must not be empty"))
        !isempty(strip(path)) || throw(ArgumentError("TLE source path must not be empty"))
        return new(String(strip(id)), String(path), verify_with_juliaspace)
    end
end

"""
    TLESourceRegistry

TLE 数据源注册表，按 `id` 索引所有已注册的数据源。

# 字段
- `sources::Dict{String,AbstractTLESource}`：从数据源 id 到 `AbstractTLESource` 实例的映射。

# 说明
注册表保证 id 唯一，并提供 `register_tle_source!`、`resolve_tle_source` 等操作。
"""
struct TLESourceRegistry
    sources::Dict{String,AbstractTLESource}

    function TLESourceRegistry(sources::Vector{<:AbstractTLESource} = AbstractTLESource[])
        by_id = Dict{String,AbstractTLESource}()
        for source in sources
            id = tle_source_id(source)
            haskey(by_id, id) && throw(ArgumentError("duplicate TLE source id: $id"))
            by_id[id] = source
        end
        return new(by_id)
    end
end

"""
    tle_source_id(source) -> String

返回给定 TLE 数据源的唯一标识。
"""
tle_source_id(source::TLETextFileSource)::String = source.id
tle_source_id(source::StarPerfTLEJsonSource)::String = source.id

"""
    register_tle_source!(registry, source) -> TLESourceRegistry

向注册表中添加一个 TLE 数据源。

若 `source` 的 id 已存在，则抛出 `ArgumentError`。
返回注册表本身，方便链式调用。
"""
function register_tle_source!(registry::TLESourceRegistry, source::AbstractTLESource)::TLESourceRegistry
    id = tle_source_id(source)
    haskey(registry.sources, id) && throw(ArgumentError("duplicate TLE source id: $id"))
    registry.sources[id] = source
    return registry
end

"""
    tle_source_ids(registry::TLESourceRegistry) -> Vector{String}

返回注册表中所有数据源 id 的排序后列表。
"""
tle_source_ids(registry::TLESourceRegistry)::Vector{String} = sort(collect(keys(registry.sources)))

"""
    resolve_tle_source(registry, id) -> AbstractTLESource

根据 id 从注册表中解析出对应的数据源。

若 id 不存在，抛出 `ArgumentError`。
"""
function resolve_tle_source(registry::TLESourceRegistry, id::AbstractString)::AbstractTLESource
    key = String(strip(id))
    haskey(registry.sources, key) || throw(ArgumentError("unknown TLE source id: $key"))
    return registry.sources[key]
end

"""
    validate_tle_record_with_juliaspace(record::TLERecordSpec) -> Nothing

使用 SatelliteToolbox 校验单条 TLE 记录是否能被正确解析。

校验和校验被关闭（`verify_checksum=false`），因为某些外部数据源可能不保证校验和正确；
这里主要检查 TLE 行的格式与数值是否合法。
"""
function validate_tle_record_with_juliaspace(record::TLERecordSpec)::Nothing
    SatelliteToolbox.read_tle(
        record.line1,
        record.line2;
        name = record.name,
        verify_checksum = false,
    )
    return nothing
end

"""
    validate_tle_records_with_juliaspace(records) -> Vector{TLERecordSpec}

批量校验 TLE 记录，返回输入的 records（用于链式使用）。
"""
function validate_tle_records_with_juliaspace(records::Vector{TLERecordSpec})::Vector{TLERecordSpec}
    for record in records
        validate_tle_record_with_juliaspace(record)
    end
    return records
end

"""
    load_tle_records(source::TLETextFileSource) -> Vector{TLERecordSpec}

从本地三行 TLE 文本文件中加载记录。

# 说明
实际解析委托给外部 `load_tle_records(path; default_name_prefix)` 函数。
若 `source.verify_with_juliaspace` 为真，加载后会逐条调用 SatelliteToolbox 校验。
"""
function load_tle_records(source::TLETextFileSource)::Vector{TLERecordSpec}
    isfile(source.path) || throw(ArgumentError("TLE source file not found: $(source.path)"))
    records = load_tle_records(source.path; default_name_prefix = source.default_name_prefix)
    source.verify_with_juliaspace && validate_tle_records_with_juliaspace(records)
    return records
end

"""
    starperf_epoch_parts(epoch::AbstractString) -> Tuple{Int,Float64}

把 StarPerf JSON 中的 ISO 时间字符串转换为 TLE 所需的 `(epoch_year, epoch_day)`。

# 说明
- `epoch_year`：年份的后两位（例如 2026 -> 26）。
- `epoch_day`：自当年 1 月 1 日 0 时起算的天数（含小数部分），TLE 标准格式中 1 月 1 日为 1.0。
"""
function starperf_epoch_parts(epoch::AbstractString)::Tuple{Int,Float64}
    dt = DateTime(String(epoch))
    epoch_full_year = Dates.year(dt)
    epoch_year = epoch_full_year % 100
    start = DateTime(epoch_full_year, 1, 1)
    epoch_day = Dates.value(dt - start) / 86_400_000 + 1
    return epoch_year, epoch_day
end

"""
    starperf_international_designator(row::AbstractDict) -> String

从 StarPerf JSON 行中提取国际设计器标识符（8 位紧凑格式）。

# 说明
StarPerf 的 `OBJECT_ID` 可能形如 "2020-001A"，需要去掉连字符并截断/补齐到 8 字符。
若字段缺失或为空，返回 "00000" 作为占位符。
"""
function starperf_international_designator(row::AbstractDict)::String
    object_id = strip(String(get(row, "OBJECT_ID", "")))
    isempty(object_id) && return "00000"
    compact = replace(object_id, "-" => "")
    return length(compact) >= 8 ? compact[1:8] : compact
end

"""
    starperf_row_to_tle_record(row::AbstractDict) -> TLERecordSpec

把 StarPerf JSON 中的一行记录转换为标准 TLE 三行记录。

# 参数
- `row::AbstractDict`：StarPerf JSON 中的单个对象，包含 `OBJECT_NAME`、`EPOCH`、
  `NORAD_CAT_ID`、`INCLINATION`、`RA_OF_ASC_NODE`、`ECCENTRICITY` 等字段。

# 返回值
`TLERecordSpec`，包含名称、TLE 第 1 行和第 2 行。

# 说明
使用 `SatelliteToolbox.TLE(...)` 构造 TLE 对象，再将其转换为字符串并拆分为三行。
"""
function starperf_row_to_tle_record(row::AbstractDict)::TLERecordSpec
    name = String(get(row, "OBJECT_NAME", "UNDEFINED"))
    epoch_year, epoch_day = starperf_epoch_parts(String(row["EPOCH"]))
    tle = SatelliteToolbox.TLE(
        name = name,
        satellite_number = Int(row["NORAD_CAT_ID"]),
        classification = first(String(get(row, "CLASSIFICATION_TYPE", "U"))),
        international_designator = starperf_international_designator(row),
        epoch_year = epoch_year,
        epoch_day = epoch_day,
        dn_o2 = Float64(get(row, "MEAN_MOTION_DOT", 0)),
        ddn_o6 = Float64(get(row, "MEAN_MOTION_DDOT", 0)),
        bstar = Float64(get(row, "BSTAR", 0)),
        element_set_number = Int(get(row, "ELEMENT_SET_NO", 0)),
        inclination = Float64(row["INCLINATION"]),
        raan = Float64(row["RA_OF_ASC_NODE"]),
        eccentricity = Float64(row["ECCENTRICITY"]),
        argument_of_perigee = Float64(row["ARG_OF_PERICENTER"]),
        mean_anomaly = Float64(row["MEAN_ANOMALY"]),
        mean_motion = Float64(row["MEAN_MOTION"]),
        revolution_number = Int(get(row, "REV_AT_EPOCH", 0)),
    )
    lines = split(convert(String, tle), '\n')
    length(lines) == 3 || throw(ArgumentError("JuliaSpace TLE conversion did not produce 3 lines"))
    return TLERecordSpec(strip(lines[1]), strip(lines[2]), strip(lines[3]))
end

"""
    load_tle_records(source::StarPerfTLEJsonSource) -> Vector{TLERecordSpec}

从 StarPerf JSON 文件中加载并转换 TLE 记录。

# 说明
文件必须是一个 JSON 数组；数组元素必须是字典（`AbstractDict`）。
转换完成后，若 `source.verify_with_juliaspace` 为真，会逐条校验生成的 TLE 行。
"""
function load_tle_records(source::StarPerfTLEJsonSource)::Vector{TLERecordSpec}
    isfile(source.path) || throw(ArgumentError("StarPerf TLE JSON not found: $(source.path)"))
    raw = JSON.parsefile(source.path)
    raw isa AbstractVector || throw(ArgumentError("StarPerf TLE JSON must be an array"))
    records = [starperf_row_to_tle_record(row) for row in raw if row isa AbstractDict]
    !isempty(records) || throw(ArgumentError("no StarPerf TLE records found"))
    source.verify_with_juliaspace && validate_tle_records_with_juliaspace(records)
    return records
end

"""
    load_tle_records(registry::TLESourceRegistry, id::AbstractString) -> Vector{TLERecordSpec}

通过注册表 id 间接加载 TLE 记录。
"""
load_tle_records(registry::TLESourceRegistry, id::AbstractString)::Vector{TLERecordSpec} =
    load_tle_records(resolve_tle_source(registry, id))

"""
    default_tle_source_registry(; project_root=joinpath(@__DIR__, "..", "..", "..", "..")) -> TLESourceRegistry

构造项目默认的 TLE 数据源注册表。

# 说明
默认注册表包含以下几类数据源：
1. 项目内置的 Celestrak / Space-Track TLE 文件（位于 `data/tle/`）。
2. StarPerf 导出的 JSON（位于项目根目录的 `攻防测试/StarPerf_Simulator-release-v2.0/`）。
3. 外部仓库 StarryNet 的 TLE 文件（假设 `DistributedSimLab/StarryNet-main 2/` 与项目根目录同级）。

注意：外部数据源路径为可选默认，若不存在可通过参数覆盖或手动注册其他数据源。
"""
function default_tle_source_registry(;
    project_root::AbstractString = joinpath(@__DIR__, "..", "..", "..", ".."),
)::TLESourceRegistry
    research_root = dirname(project_root)
    registry = TLESourceRegistry()
    register_tle_source!(
        registry,
        TLETextFileSource(
            "celestrak-starlink",
            joinpath(project_root, "data", "tle", "celestrak", "starlink_gp_latest.tle");
            default_name_prefix = "STARLINK",
        ),
    )
    register_tle_source!(
        registry,
        TLETextFileSource(
            "celestrak-starlink-legacy",
            joinpath(project_root, "data", "tle", "celestrak", "starlink_latest_legacy_copy.tle");
            default_name_prefix = "STARLINK",
        ),
    )
    register_tle_source!(
        registry,
        TLETextFileSource(
            "spacetrack-starlink-show",
            joinpath(project_root, "data", "tle", "spacetrack", "starlink_spacetrack_show.tle");
            default_name_prefix = "STARLINK",
        ),
    )
    register_tle_source!(
        registry,
        TLETextFileSource(
            "starrynet-starlink",
            joinpath(research_root, "DistributedSimLab", "StarryNet-main 2", "tle", "Starlink.tle");
            default_name_prefix = "STARLINK",
        ),
    )
    register_tle_source!(
        registry,
        StarPerfTLEJsonSource(
            "starperf-starlink-json",
            joinpath(project_root, "攻防测试", "StarPerf_Simulator-release-v2.0", "tle.json"),
        ),
    )
    return registry
end

# OMM/GP（CCSDS 502.0-B-3）JSON 数据源支持。
#
# Celestrak 的 GP JSON 是 OMM 字段的平面对象数组。本模块只做最小解析：
# 依赖 src/orbit 已有的 JSON 包，解析顶层数组，并检查每个对象包含 SGP4 初始化
# 所需的必需字段。不支持嵌套对象、转义字符串等完整 JSON 特性之外的花哨扩展。
#
# 实现要点：
#   - OMM 记录直接通过 SatelliteToolboxSgp4.sgp4_init(epoch_jd, n0, e0, i0, raan, argp, M0, bstar)
#     初始化，绕开 TLE 5 位目录号的格式限制，因此原生支持 9 位目录号。
#   - 提供 OMMJsonFileSource 与 read_omm_json，与 TLE 数据源遵循同一套 abstract type + 多重分派风格。

using Dates
using JSON
import SatelliteToolbox
import SatelliteToolboxSgp4

export OMMOrbitElementSet
export AbstractOMMSource, OMMJsonFileSource, omm_source_id, load_omm_records
export read_omm_json

const _DEG_TO_RAD = π / 180.0
const _REV_DAY_TO_RAD_MIN = 2π / (24 * 60)   # 约 0.00436332313 rad/min
const _J2000 = DateTime(2000, 1, 1, 12, 0, 0)

function _datetime_to_jd(dt::DateTime)::Float64
    return 2451545.0 + Dates.value(Dates.Millisecond(dt - _J2000)) / 86400000.0
end

function _jd_to_datetime(jd::Real)::DateTime
    return _J2000 + Dates.Millisecond(round(Int, (Float64(jd) - 2451545.0) * 86400000.0))
end

"""
    OMMOrbitElementSet <: AbstractOrbitElementSet

OMM/GP 轨道根数。

直接保存 SGP4 初始化所需的原始数值（epoch 为儒略日，角度为弧度，平均运动为 rad/min），
避免 TLE 两行格式对目录号（5 位）和字段精度的限制，因此原生支持 9 位 NORAD 目录号。

字段可通过属性访问原始 OMM 单位：
  - `epoch`：DateTime
  - `mean_motion_rev_per_day`、`inclination_deg`、`raan_deg`、
    `arg_of_pericenter_deg`、`mean_anomaly_deg` 等
"""
struct OMMOrbitElementSet <: AbstractOrbitElementSet
    name::String
    object_id::String
    norad_cat_id::Int
    epoch_jd::Float64
    mean_motion_rad_min::Float64
    eccentricity::Float64
    inclination_rad::Float64
    raan_rad::Float64
    arg_of_pericenter_rad::Float64
    mean_anomaly_rad::Float64
    bstar::Float64
    mean_motion_dot_rev_per_day2::Float64
    mean_motion_ddot_rev_per_day3::Float64
    classification::Char
    element_set_no::Int
    rev_at_epoch::Int
    metadata::SourceMetadata
end

function OMMOrbitElementSet(;
    name::AbstractString,
    object_id::AbstractString,
    norad_cat_id::Int,
    epoch::Union{DateTime,Real},
    mean_motion_rev_per_day::Real,
    eccentricity::Real,
    inclination_deg::Real,
    raan_deg::Real,
    arg_of_pericenter_deg::Real,
    mean_anomaly_deg::Real,
    bstar::Real,
    mean_motion_dot_rev_per_day2::Real = 0.0,
    mean_motion_ddot_rev_per_day3::Real = 0.0,
    classification::AbstractString = "U",
    element_set_no::Int = 0,
    rev_at_epoch::Int = 0,
    metadata::SourceMetadata = SourceMetadata("omm"),
)
    epoch_jd = epoch isa DateTime ? _datetime_to_jd(epoch) : Float64(epoch)
    mean_motion_rad_min = Float64(mean_motion_rev_per_day) * _REV_DAY_TO_RAD_MIN
    0 <= eccentricity < 1 || throw(ArgumentError("eccentricity must be in [0, 1)"))
    mean_motion_rad_min > 0 || throw(ArgumentError("mean_motion must be positive"))
    norad_cat_id >= 0 || throw(ArgumentError("norad_cat_id must be non-negative"))
    length(classification) == 1 || throw(ArgumentError("classification must be a single character"))
    return OMMOrbitElementSet(
        String(name), String(object_id), Int(norad_cat_id), epoch_jd,
        mean_motion_rad_min, Float64(eccentricity),
        Float64(inclination_deg) * _DEG_TO_RAD,
        Float64(raan_deg) * _DEG_TO_RAD,
        Float64(arg_of_pericenter_deg) * _DEG_TO_RAD,
        Float64(mean_anomaly_deg) * _DEG_TO_RAD,
        Float64(bstar),
        Float64(mean_motion_dot_rev_per_day2),
        Float64(mean_motion_ddot_rev_per_day3),
        first(classification),
        Int(element_set_no),
        Int(rev_at_epoch),
        metadata,
    )
end

function Base.getproperty(el::OMMOrbitElementSet, name::Symbol)
    if name === :epoch
        return _jd_to_datetime(getfield(el, :epoch_jd))
    elseif name === :mean_motion_rev_per_day
        return getfield(el, :mean_motion_rad_min) / _REV_DAY_TO_RAD_MIN
    elseif name === :inclination_deg
        return getfield(el, :inclination_rad) / _DEG_TO_RAD
    elseif name === :raan_deg
        return getfield(el, :raan_rad) / _DEG_TO_RAD
    elseif name === :arg_of_pericenter_deg
        return getfield(el, :arg_of_pericenter_rad) / _DEG_TO_RAD
    elseif name === :mean_anomaly_deg
        return getfield(el, :mean_anomaly_rad) / _DEG_TO_RAD
    else
        return getfield(el, name)
    end
end

Base.propertynames(::OMMOrbitElementSet) = (
    :name, :object_id, :norad_cat_id, :epoch, :epoch_jd,
    :mean_motion_rev_per_day, :mean_motion_rad_min,
    :eccentricity,
    :inclination_deg, :inclination_rad,
    :raan_deg, :raan_rad,
    :arg_of_pericenter_deg, :arg_of_pericenter_rad,
    :mean_anomaly_deg, :mean_anomaly_rad,
    :bstar, :mean_motion_dot_rev_per_day2, :mean_motion_ddot_rev_per_day3,
    :classification, :element_set_no, :rev_at_epoch, :metadata,
)

function _omm_get_number(row::AbstractDict, key::AbstractString)::Float64
    haskey(row, key) || throw(ArgumentError("OMM record missing required field: $key"))
    v = row[key]
    v isa Number && return Float64(v)
    v isa AbstractString && return parse(Float64, String(v))
    throw(ArgumentError("OMM field $key must be a number or numeric string, got $(typeof(v))"))
end

function _omm_get_number(row::AbstractDict, key::AbstractString, default::Real)::Float64
    haskey(row, key) || return Float64(default)
    return _omm_get_number(row, key)
end

function _omm_get_int(row::AbstractDict, key::AbstractString)::Int
    haskey(row, key) || throw(ArgumentError("OMM record missing required field: $key"))
    v = row[key]
    v isa Integer && return Int(v)
    v isa AbstractString && return parse(Int, String(v))
    v isa Number && return Int(round(v))
    throw(ArgumentError("OMM field $key must be an integer, got $(typeof(v))"))
end

function _omm_get_int(row::AbstractDict, key::AbstractString, default::Int)::Int
    haskey(row, key) || return default
    return _omm_get_int(row, key)
end

function _omm_get_string(row::AbstractDict, key::AbstractString)::String
    haskey(row, key) || throw(ArgumentError("OMM record missing required field: $key"))
    return String(row[key])
end

function _omm_epoch_jd(row::AbstractDict)::Float64
    haskey(row, "EPOCH") || throw(ArgumentError("OMM record missing required field: EPOCH"))
    v = row["EPOCH"]
    if v isa Number
        return Float64(v)
    elseif v isa AbstractString
        epoch_str = String(v)
        dt = tryparse(DateTime, epoch_str)
        dt !== nothing && return _datetime_to_jd(dt)
        # Celestrak GP JSON 的 EPOCH 带 6 位小数秒（微秒），超出 DateTime 的毫秒精度，
        # tryparse 会失败；此处拆出小数秒单独换算为儒略日的小数部分。
        m = match(r"^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2})\.(\d+)$", epoch_str)
        if m !== nothing
            base = tryparse(DateTime, m.captures[1])
            if base !== nothing
                frac_s = parse(Float64, "0." * m.captures[2])
                return _datetime_to_jd(base) + frac_s / 86400.0
            end
        end
        throw(ArgumentError("invalid OMM epoch string: $epoch_str"))
    else
        throw(ArgumentError("OMM field EPOCH must be an ISO date string or a Julian Day number, got $(typeof(v))"))
    end
end

"""
    omm_row_to_element_set(row::AbstractDict) -> OMMOrbitElementSet

把一条 Celestrak GP JSON 记录转换为 `OMMOrbitElementSet`。

必需字段：OBJECT_NAME, EPOCH, NORAD_CAT_ID, MEAN_MOTION, ECCENTRICITY,
INCLINATION, RA_OF_ASC_NODE, ARG_OF_PERICENTER, MEAN_ANOMALY, BSTAR。
"""
function omm_row_to_element_set(row::AbstractDict)::OMMOrbitElementSet
    name = _omm_get_string(row, "OBJECT_NAME")
    object_id = get(row, "OBJECT_ID", "")
    object_id isa AbstractString || (object_id = "")
    norad_cat_id = _omm_get_int(row, "NORAD_CAT_ID")
    epoch_jd = _omm_epoch_jd(row)
    return OMMOrbitElementSet(
        name = name,
        object_id = String(object_id),
        norad_cat_id = norad_cat_id,
        epoch = epoch_jd,
        mean_motion_rev_per_day = _omm_get_number(row, "MEAN_MOTION"),
        eccentricity = _omm_get_number(row, "ECCENTRICITY"),
        inclination_deg = _omm_get_number(row, "INCLINATION"),
        raan_deg = _omm_get_number(row, "RA_OF_ASC_NODE"),
        arg_of_pericenter_deg = _omm_get_number(row, "ARG_OF_PERICENTER"),
        mean_anomaly_deg = _omm_get_number(row, "MEAN_ANOMALY"),
        bstar = _omm_get_number(row, "BSTAR"),
        mean_motion_dot_rev_per_day2 = _omm_get_number(row, "MEAN_MOTION_DOT", 0.0),
        mean_motion_ddot_rev_per_day3 = _omm_get_number(row, "MEAN_MOTION_DDOT", 0.0),
        classification = string(get(row, "CLASSIFICATION_TYPE", "U")),
        element_set_no = _omm_get_int(row, "ELEMENT_SET_NO", 0),
        rev_at_epoch = _omm_get_int(row, "REV_AT_EPOCH", 0),
        metadata = SourceMetadata("omm"),
    )
end

"""
    read_omm_json(path_or_string) -> Vector{OMMOrbitElementSet}

读取 Celestrak GP JSON（文件路径或 JSON 字符串），返回 OMM 元素集列表。
"""
function read_omm_json(input::AbstractString)::Vector{OMMOrbitElementSet}
    # 长 JSON 字符串直接按内容解析，避免 isfile 对超长路径名调用 stat。
    raw = if occursin(r"^\s*[\[\{]", input)
        JSON.parse(input)
    elseif isfile(input)
        JSON.parsefile(input)
    else
        JSON.parse(input)
    end
    raw isa AbstractVector || throw(ArgumentError("OMM GP JSON must be a top-level array of objects"))
    return [omm_row_to_element_set(row) for row in raw if row isa AbstractDict]
end

"""
    AbstractOMMSource

OMM 数据源的抽象基类型，与 `AbstractTLESource` 并列，遵循同一套数据源分派模式。
"""
abstract type AbstractOMMSource end

"""
    OMMJsonFileSource <: AbstractOMMSource

本地 Celestrak GP JSON 文件数据源。

字段：
  - `id::String`：数据源标识。
  - `path::String`：JSON 文件路径。
"""
struct OMMJsonFileSource <: AbstractOMMSource
    id::String
    path::String

    function OMMJsonFileSource(id::AbstractString, path::AbstractString)
        !isempty(strip(id)) || throw(ArgumentError("OMM source id must not be empty"))
        !isempty(strip(path)) || throw(ArgumentError("OMM source path must not be empty"))
        return new(String(strip(id)), String(path))
    end
end

omm_source_id(source::OMMJsonFileSource)::String = source.id

"""
    load_omm_records(source::OMMJsonFileSource) -> Vector{OMMOrbitElementSet}

从 OMM JSON 文件数据源加载记录。
"""
function load_omm_records(source::OMMJsonFileSource)::Vector{OMMOrbitElementSet}
    isfile(source.path) || throw(ArgumentError("OMM JSON source file not found: $(source.path)"))
    return read_omm_json(source.path)
end

# ════════════════════════════════════════════════════════════════
# OMM/GP → 裸数组 ECEF 桥接（SGP4 直接初始化，无 TLE 字符串往返）
# ════════════════════════════════════════════════════════════════

function SatelliteSimOrbit.propagate_to_ecef(
    omm_elements::Vector{OMMOrbitElementSet},
    time_grid::SimulationTimeGrid;
)::Array{Float64,3}
    n_sats = length(omm_elements)
    n_time = time_count(time_grid)
    pos_ecef = zeros(n_sats, n_time, 3)
    offsets = timeslot_offsets(time_grid)

    Threads.@threads for i in 1:n_sats
        el = omm_elements[i]
        sgp4d = SatelliteToolboxSgp4.sgp4_init(
            el.epoch_jd,
            el.mean_motion_rad_min,
            el.eccentricity,
            el.inclination_rad,
            el.raan_rad,
            el.arg_of_pericenter_rad,
            el.mean_anomaly_rad,
            el.bstar,
        )

        for j in 1:n_time
            elapsed_s = offsets[j]
            target_time = time_grid.epoch.instant + Dates.Millisecond(1000 * elapsed_s)
            jd = _datetime_to_jd(target_time)
            elapsed_min = (jd - el.epoch_jd) * 1440.0
            r_teme, _ = SatelliteToolboxSgp4.sgp4!(sgp4d, elapsed_min)
            D = SatelliteToolbox.r_eci_to_ecef(
                SatelliteToolbox.TEME(),
                SatelliteToolbox.PEF(),
                jd,
            )
            r_ecef = D * r_teme
            pos_ecef[i, j, 1] = r_ecef[1]
            pos_ecef[i, j, 2] = r_ecef[2]
            pos_ecef[i, j, 3] = r_ecef[3]
        end
    end

    return pos_ecef
end

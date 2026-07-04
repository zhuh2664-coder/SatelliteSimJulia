# ===== 约束目录 =====

export list_constraints, describe_constraint

"""
    ConstraintInfo

物理约束元信息。

# 字段
- `id::Symbol`: 唯一标识
- `name::String`: 显示名称
- `description::String`: 约束说明
- `unit::String`: 单位
- `default_value::Float64`: LEO 默认值
- `category::Symbol`: 类别（:isl, :gsl, :satellite）
"""
struct ConstraintInfo
    id::Symbol
    name::String
    description::String
    unit::String
    default_value::Float64
    category::Symbol
end

const CONSTRAINT_CATALOG = Dict{Symbol,ConstraintInfo}(
    :isl_max_range => ConstraintInfo(
        :isl_max_range, "ISL 最大距离", "星间链路最大通信距离", "km", 5000.0, :isl,
    ),
    :gsl_min_elevation => ConstraintInfo(
        :gsl_min_elevation, "GSL 最小仰角", "地面站最小通信仰角", "deg", 25.0, :gsl,
    ),
    :gsl_max_range => ConstraintInfo(
        :gsl_max_range, "GSL 最大距离", "星地链路最大通信距离", "km", 2000.0, :gsl,
    ),
    :isl_max_capacity => ConstraintInfo(
        :isl_max_capacity, "ISL 最大容量", "星间链路最大带宽", "Mbps", 10000.0, :isl,
    ),
    :gsl_base_capacity => ConstraintInfo(
        :gsl_base_capacity, "GSL 基准容量", "星地链路基准带宽", "Mbps", 1000.0, :gsl,
    ),
    :max_isl_per_satellite => ConstraintInfo(
        :max_isl_per_satellite, "每星最大 ISL 数", "单颗卫星最多 ISL 连接数", "个", 4.0, :satellite,
    ),
)

list_constraints() = sort(collect(keys(CONSTRAINT_CATALOG)),
    by = id -> CONSTRAINT_CATALOG[id].name)

function describe_constraint(id::Symbol)
    haskey(CONSTRAINT_CATALOG, id) || return "unknown constraint: $id"
    c = CONSTRAINT_CATALOG[id]
    return "$(c.name): $(c.description) [默认: $(c.default_value) $(c.unit), 类别: $(c.category)]"
end

function default_constraints()
    return PhysicalConstraints(
        isl_max_range_km = CONSTRAINT_CATALOG[:isl_max_range].default_value,
        gsl_min_elevation_deg = CONSTRAINT_CATALOG[:gsl_min_elevation].default_value,
        gsl_max_range_km = CONSTRAINT_CATALOG[:gsl_max_range].default_value,
        isl_max_capacity_mbps = CONSTRAINT_CATALOG[:isl_max_capacity].default_value,
        gsl_base_capacity_mbps = CONSTRAINT_CATALOG[:gsl_base_capacity].default_value,
        max_isl_per_satellite = Int(CONSTRAINT_CATALOG[:max_isl_per_satellite].default_value),
    )
end

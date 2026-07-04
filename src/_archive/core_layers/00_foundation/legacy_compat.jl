# ===== 临时兼容层：旧类型 → 新类型映射 =====
# 重构完成后删除此文件。
#
# 此文件提供旧类型到新类型的映射，让 Layer 1-2 文件能够编译。
# 重构完成后，所有引用这些类型的代码都应该使用新的类型系统。

export SatelliteId, Constellation, SatelliteStatus, StateConfig
export ACTIVE, INACTIVE, FAILED, DECOMMISSIONED

# ════════════════════════════════════════════════════════════
# 1. SatelliteId 映射
# ════════════════════════════════════════════════════════════

# 旧 SatelliteId 是分层索引结构：
# struct SatelliteId
#     global_id::Int
#     shell_id::Int
#     orbit_plane_id::Int
#     index_in_plane::Int
#     ...
# end
#
# 新版简化为直接使用 Int
const SatelliteId = Int

# ════════════════════════════════════════════════════════════
# 2. Constellation 映射
# ════════════════════════════════════════════════════════════

# 旧 Constellation 是复杂结构：
# struct Constellation
#     id::String
#     shells::Vector{Shell}
#     satellites::Dict{SatelliteId, Satellite}
#     ...
# end
#
# 新版简化为 Vector{Satellite}
const Constellation = Vector{Satellite}

# ════════════════════════════════════════════════════════════
# 3. SatelliteStatus 枚举
# ════════════════════════════════════════════════════════════

# 旧版在 LegacyEntities 中定义
@enum SatelliteStatus ACTIVE INACTIVE FAILED DECOMMISSIONED

# ════════════════════════════════════════════════════════════
# 4. StateConfig 结构
# ════════════════════════════════════════════════════════════

# 旧版用于 build_satellite() 的初始状态参数
# 新版不再需要，位置由传播器返回
# 这里提供简化版本以保持兼容性
Base.@kwdef struct StateConfig
    x::Float64 = 0.0
    y::Float64 = 0.0
    z::Float64 = 0.0
    vx::Float64 = 0.0
    vy::Float64 = 0.0
    vz::Float64 = 0.0
    status::SatelliteStatus = ACTIVE
end

# ════════════════════════════════════════════════════════════
# 重构说明
# ════════════════════════════════════════════════════════════

# 当所有 Layer 1-2 文件完成重构后：
# 1. 删除此文件
# 2. 删除 _legacy_bridge/ 目录
# 3. 确保所有代码使用新类型：
#    - Satellite (id::Int, orbit, config)
#    - GroundStation (id::Int, position)
#    - UserTerminal (id::Int, position)
#    - 位置数据由传播器返回 Array{Float64,3}

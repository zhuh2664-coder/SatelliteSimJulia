# ===== HandoverPolicy 多分派（切换策略）=====
#
# 调研.md §3.4 + §11.2：GSL 接入选择策略应可自定义。
# 当前 access.jl 硬编码 max-elevation，本文件提供多分派框架。
#
# 新策略 = 新类型 + 新方法，不改已有代码（多重分派原则）。

export AbstractHandoverPolicy, ElevationThreshold, LongestVisible, NearestDistance,
       select_satellite, count_handovers

# ────────────────────────────────────────────────────────────
# 抽象类型 + 策略类型
# ────────────────────────────────────────────────────────────

"""切换策略抽象类型"""
abstract type AbstractHandoverPolicy end

"""
    ElevationThreshold

仰角阈值策略：选仰角 ≥ min_elevation_deg 里仰角最高的卫星。
这是传统默认策略（等价于原来的 _best_access_sample）。
"""
struct ElevationThreshold <: AbstractHandoverPolicy
    min_elevation_deg::Float64
end
ElevationThreshold() = ElevationThreshold(0.0)

"""
    LongestVisible

滞回策略：如果上一时刻选中的卫星仍然可见，就保持不变（减少乒乓切换）。
只有当前卫星不可见时，才切换到仰角最高的可见卫星。
"""
struct LongestVisible <: AbstractHandoverPolicy
    min_elevation_deg::Float64
end
LongestVisible() = LongestVisible(0.0)

"""
    NearestDistance

最近距离策略：选距离地面站最近的卫星（距离最小）。
"""
struct NearestDistance <: AbstractHandoverPolicy end

# ────────────────────────────────────────────────────────────
# select_satellite 多分派
# ────────────────────────────────────────────────────────────

"""
    select_satellite(policy, samples[, prev_satellite_id]) -> Union{Nothing,GSLPhysicalLinkSample}

按策略从可见卫星样本中选择接入卫星。
"""
function select_satellite(
    policy::ElevationThreshold,
    samples::Vector{<:GSLPhysicalLinkSample},
    prev_satellite_id::Union{Nothing,Int}=nothing,
)
    isempty(samples) && return nothing
    filtered = filter(s -> s.elevation_deg >= policy.min_elevation_deg, samples)
    isempty(filtered) && return nothing
    return argmax(s -> s.elevation_deg, filtered)
end

function select_satellite(
    policy::LongestVisible,
    samples::Vector{<:GSLPhysicalLinkSample},
    prev_satellite_id::Union{Nothing,Int}=nothing,
)
    isempty(samples) && return nothing
    filtered = filter(s -> s.elevation_deg >= policy.min_elevation_deg, samples)

    # 滞回：如果上一时刻的卫星仍可见，保持
    if prev_satellite_id !== nothing
        kept = filter(s -> s.satellite_id == prev_satellite_id, filtered)
        isempty(kept) || return first(kept)
    end

    # 否则切换到仰角最高的
    isempty(filtered) && return nothing
    return argmax(s -> s.elevation_deg, filtered)
end

function select_satellite(
    policy::NearestDistance,
    samples::Vector{<:GSLPhysicalLinkSample},
    prev_satellite_id::Union{Nothing,Int}=nothing,
)
    isempty(samples) && return nothing
    return argmin(s -> s.distance_km, samples)
end

# ────────────────────────────────────────────────────────────
# 切换频次统计
# ────────────────────────────────────────────────────────────

"""
    count_handovers(selected_ids::Vector{Union{Nothing,Int}}) -> Int

统计切换次数：相邻时刻选中的卫星 ID 不同即为一次切换。
"""
function count_handovers(selected_ids::Vector{Union{Nothing,Int}})
    n = 0
    for i in 2:length(selected_ids)
        if selected_ids[i] !== nothing && selected_ids[i-1] !== nothing
            selected_ids[i] != selected_ids[i-1] && (n += 1)
        elseif selected_ids[i] !== nothing && selected_ids[i-1] === nothing
            n += 1  # 从无到有也算切换
        end
    end
    return n
end

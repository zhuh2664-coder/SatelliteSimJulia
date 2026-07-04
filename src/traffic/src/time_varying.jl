# ===== 时间序列需求（TimeVaryingDemand）=====
#
# 支持时变速率需求。设计原则：不修改 TrafficDemand struct（向后兼容），
# 而是提供时变需求类型，它能在任意时刻查询速率，并可展开成多个
# 恒定 TrafficDemand（每时间窗一个）喂给现有 AON。
#
# 新增于 2026-07-04（Phase 1 - A3）。

using Random

export
    AbstractRateProfile,
    ConstantRate,
    SampledRate,
    FunctionalRate,
    TimeVaryingDemand,
    rate_at,
    expand_to_demands

# ────────────────────────────────────────────────────────────
# 速率曲线（抽象接口）
# ────────────────────────────────────────────────────────────

"""
    AbstractRateProfile

速率随时间变化的抽象接口。每种实现定义 rate_at(profile, elapsed_s) -> Mbps。
"""
abstract type AbstractRateProfile end

"""
    rate_at(profile, elapsed_s) -> Float64

查询 `elapsed_s` 时刻的速率（Mbps）。
"""
function rate_at end

"""恒定速率（等价于普通 TrafficDemand）。"""
struct ConstantRate <: AbstractRateProfile
    rate_mbps::Float64
end
rate_at(p::ConstantRate, elapsed_s::Int)::Float64 = p.rate_mbps

"""
    SampledRate

采样序列：给定时间点序列和对应速率序列，线性插值查询任意时刻。

# 字段
- `times_s::Vector{Int}`: 时间点（秒，严格递增）
- `rates_mbps::Vector{Float64}`: 对应速率

适用于：从真实 trace 或昼夜模式生成的离散采样。
"""
struct SampledRate <: AbstractRateProfile
    times_s::Vector{Int}
    rates_mbps::Vector{Float64}

    function SampledRate(times_s::Vector{Int}, rates_mbps::Vector{Float64})
        length(times_s) == length(rates_mbps) ||
            throw(ArgumentError("times_s and rates_mbps must have equal length"))
        length(times_s) >= 1 || throw(ArgumentError("need at least one sample"))
        issorted(times_s) ||
            throw(ArgumentError("times_s must be strictly increasing"))
        all(r -> r >= 0, rates_mbps) ||
            throw(ArgumentError("rates must be non-negative"))
        return new(times_s, rates_mbps)
    end
end

function rate_at(p::SampledRate, elapsed_s::Int)::Float64
    t, r = p.times_s, p.rates_mbps
    elapsed_s <= t[1] && return r[1]
    elapsed_s >= t[end] && return r[end]
    # 二分查找区间
    lo, hi = 1, length(t)
    while lo + 1 < hi
        mid = (lo + hi) ÷ 2
        if t[mid] <= elapsed_s
            lo = mid
        else
            hi = mid
        end
    end
    # 线性插值 [lo, hi]
    frac = (elapsed_s - t[lo]) / (t[hi] - t[lo])
    return r[lo] + frac * (r[hi] - r[lo])
end

"""
    FunctionalRate

任意速率函数：rate_mbps = f(elapsed_s)。

适用于：解析速率曲线（如正弦昼夜、指数衰减）。
"""
struct FunctionalRate <: AbstractRateProfile
    func::Function
end
rate_at(p::FunctionalRate, elapsed_s::Int)::Float64 = max(0.0, p.func(elapsed_s))

# ────────────────────────────────────────────────────────────
# 时变需求
# ────────────────────────────────────────────────────────────

"""
    TimeVaryingDemand

速率随时间变化的需求。和 TrafficDemand 字段一致（id/source/destination/时间窗），
但速率由 AbstractRateProfile 描述（恒定/采样/函数），可在任意时刻查询。

通过 expand_to_demands 展开成多个恒定 TrafficDemand 喂给现有 AON。
"""
struct TimeVaryingDemand
    id::Int
    source_ground_id::Int
    destination_ground_id::Int
    start_elapsed_s::Int
    end_elapsed_s::Int
    rate_profile::AbstractRateProfile
end

"""
    rate_at(demand::TimeVaryingDemand, elapsed_s) -> Float64

查询时变需求在某时刻的速率（仅活跃时有意义）。
"""
rate_at(demand::TimeVaryingDemand, elapsed_s::Int)::Float64 =
    rate_at(demand.rate_profile, elapsed_s)

"""
    expand_to_demands(demand::TimeVaryingDemand; step_s) -> Vector{TrafficDemand}

把时变需求展开成多个恒定 TrafficDemand，每 `step_s` 秒一个时间窗，
每个窗的速率取窗中心的瞬时速率。

这是把时变需求接入现有 AON（只认恒定 TrafficDemand）的桥梁。
展开后每条子需求的 id 共享父 id（AON 要求 id 唯一，调用者负责加唯一前缀）。
"""
function expand_to_demands(demand::TimeVaryingDemand; step_s::Int = 60)::Vector{TrafficDemand}
    step_s > 0 || throw(ArgumentError("step_s must be positive"))
    result = TrafficDemand[]
    win_start = demand.start_elapsed_s
    sub_id = 0
    while win_start < demand.end_elapsed_s
        win_end = min(win_start + step_s, demand.end_elapsed_s)
        center = (win_start + win_end) ÷ 2
        rate = rate_at(demand, center)
        if rate > 0
            sub_id += 1
            push!(result, TrafficDemand(;
                id = demand.id * 100_000 + sub_id,  # 唯一性：父 id × 10万 + 子序号
                source_ground_id = demand.source_ground_id,
                destination_ground_id = demand.destination_ground_id,
                start_elapsed_s = win_start,
                end_elapsed_s = win_end,
                rate_mbps = rate,
            ))
        end
        win_start = win_end
    end
    return result
end

"""
    expand_to_demands(demands::Vector{TimeVaryingDemand}; step_s) -> Vector{TrafficDemand}

批量展开多个时变需求为恒定需求列表。
"""
function expand_to_demands(demands::Vector{TimeVaryingDemand}; step_s::Int = 60)::Vector{TrafficDemand}
    return vcat([expand_to_demands(d; step_s=step_s) for d in demands]...)
end

# ────────────────────────────────────────────────────────────
# 便捷构造器：从采样序列或函数直接建时变需求
# ────────────────────────────────────────────────────────────

"""
    time_varying_demand_from_samples(id, src, dst, t0, t1, times, rates) -> TimeVaryingDemand

从采样时间/速率序列构造时变需求。times/rates 会被裁剪到 [t0, t1] 窗口内。
"""
function time_varying_demand_from_samples(
    id::Int, src::Int, dst::Int, t0::Int, t1::Int,
    times::Vector{Int}, rates::Vector{Float64},
)::TimeVaryingDemand
    return TimeVaryingDemand(id, src, dst, t0, t1, SampledRate(times, rates))
end

"""
    time_varying_demand_from_func(id, src, dst, t0, t1, func) -> TimeVaryingDemand

从速率函数构造时变需求。func 接受 elapsed_s 返回 Mbps。
"""
function time_varying_demand_from_func(
    id::Int, src::Int, dst::Int, t0::Int, t1::Int, func::Function,
)::TimeVaryingDemand
    return TimeVaryingDemand(id, src, dst, t0, t1, FunctionalRate(func))
end

# ===== 指标计算 =====
# 纯函数，输入算法层输出 → 输出指标值。
# 原则：只算不存，不依赖实体类型，不调用算法层。

using Statistics: mean

export CoverageResult, LatencyResult, NetworkMetrics, UtilizationResult,
       RoutingMetrics,
       compute_coverage, compute_latency, latency_cdf, compute_network_metrics,
       compute_link_utilization, compute_routing_metrics,
       compute_temporal_coverage

# ----- 覆盖率 -----

"""
    CoverageResult

覆盖率计算结果。

# 字段
- `coverage_ratio::Float64`: 覆盖率 (0-1)
- `covered_users::Vector{Int}`: 被覆盖的用户索引
- `total_users::Int`: 总用户数
"""
struct CoverageResult
    coverage_ratio::Float64
    covered_users::Vector{Int}
    total_users::Int
end

"""
    compute_coverage(gsl_matrix, user_ids) -> CoverageResult

计算覆盖率。

# 参数
- `gsl_matrix::Matrix{Bool}`: (N_sat, N_user) 每颗卫星对每个用户的 GSL 可用性
- `user_ids::Vector{String}`: 用户 ID 列表（仅用于返回覆盖的用户数）

# 返回
`CoverageResult` — 覆盖率、被覆盖用户数、总用户数
"""
function compute_coverage(gsl_matrix::AbstractMatrix{Bool}, user_ids::Vector{String})::CoverageResult
    n_users = size(gsl_matrix, 2)
    n_users == length(user_ids) || throw(ArgumentError("gsl_matrix columns must match user_ids length"))
    n_users == 0 && return CoverageResult(0.0, Int[], 0)

    covered = falses(n_users)
    for j in 1:n_users
        covered[j] = any(gsl_matrix[:, j])
    end

    covered_indices = findall(covered)
    ratio = length(covered_indices) / n_users

    return CoverageResult(ratio, covered_indices, n_users)
end

# ----- 延迟 -----

"""
    LatencyResult

延迟计算结果。

# 字段
- `avg_latency_ms::Float64`: 平均延迟 (ms)
- `max_latency_ms::Float64`: 最大延迟 (ms)
- `min_latency_ms::Float64`: 最小延迟 (ms)
- `path_count::Int`: 有效路径数
"""
struct LatencyResult
    avg_latency_ms::Float64
    max_latency_ms::Float64
    min_latency_ms::Float64
    path_count::Int
    p50_ms::Float64
    p95_ms::Float64
    p99_ms::Float64
    samples_ms::Vector{Float64}
end

# 向后兼容：旧 4 参数构造仍可用
function LatencyResult(avg::Float64, mx::Float64, mn::Float64, count::Int)
    return LatencyResult(avg, mx, mn, count, avg, mx, mx, Float64[])
end

"""
    compute_latency(distance_matrix) -> LatencyResult

计算端到端延迟统计（含百分位 p50/p95/p99 + 原始样本）。

# 参数
- `distance_matrix::Matrix{Float64}`: 全对最短路径距离矩阵 (ms)

# 返回
`LatencyResult` — 平均/最大/最小/p50/p95/p99 延迟，有效路径数，原始样本（供 CDF 画图）
"""
function compute_latency(distance_matrix::AbstractMatrix{Float64})::LatencyResult
    n = size(distance_matrix, 1)
    # 排除对角线 (i == j) 和不可达 (Inf)
    mask = trues(n, n)
    for i in 1:n
        mask[i, i] = false
    end
    finite_vals = distance_matrix[mask .& isfinite.(distance_matrix)]

    if isempty(finite_vals)
        return LatencyResult(0.0, 0.0, 0.0, 0)
    end

    sorted_vals = sort(finite_vals)
    p50 = quantile(sorted_vals, 0.50)
    p95 = quantile(sorted_vals, 0.95)
    p99 = quantile(sorted_vals, 0.99)

    return LatencyResult(
        mean(finite_vals),
        maximum(finite_vals),
        minimum(finite_vals),
        length(finite_vals),
        p50,
        p95,
        p99,
        sorted_vals,
    )
end

"""
    latency_cdf(samples_ms; n_bins=100) -> (bin_edges, cumulative_probs)

计算延迟样本的 CDF（累积分布函数），供可视化画 CDF 曲线。
"""
function latency_cdf(samples_ms::AbstractVector{<:Real}; n_bins::Int=100)
    isempty(samples_ms) && return (Float64[], Float64[])
    sorted = sort(samples_ms)
    lo, hi = sorted[1], sorted[end]
    lo == hi && return ([lo, hi], [0.0, 1.0])
    edges = collect(range(lo, hi; length=n_bins+1))
    counts = zeros(Float64, n_bins)
    for s in sorted
        idx = min(n_bins, max(1, ceil(Int, (s - lo) / (hi - lo) * n_bins)))
        counts[idx] += 1
    end
    cumulative = cumsum(counts) / length(sorted)
    return edges, [0.0, cumulative...]
end

# ----- 网络指标 -----

"""
    NetworkMetrics

网络级指标。

# 字段
- `diameter::Float64`: 网络直径（所有最短路径的最大值）
- `avg_path_length::Float64`: 平均最短路径长度
- `is_connected::Bool`: 是否全连通
- `connectivity_ratio::Float64`: 连通比例 (0-1)
"""
struct NetworkMetrics
    diameter::Float64
    avg_path_length::Float64
    is_connected::Bool
    connectivity_ratio::Float64
end

"""
    compute_network_metrics(distance_matrix) -> NetworkMetrics

计算网络级指标。

# 参数
- `distance_matrix::Matrix{Float64}`: 全对最短路径距离矩阵

# 返回
`NetworkMetrics` — 直径、平均路径长度、连通性
"""
function compute_network_metrics(distance_matrix::AbstractMatrix{Float64})::NetworkMetrics
    n = size(distance_matrix, 1)
    total_pairs = n * (n - 1)  # 排除对角线

    # 统计有限值
    finite_mask = isfinite.(distance_matrix)
    finite_count = count(finite_mask) - n  # 排除对角线
    finite_vals = distance_matrix[finite_mask]

    # 过滤掉对角线
    non_diag = Float64[]
    for i in 1:n
        for j in 1:n
            if i != j && isfinite(distance_matrix[i, j])
                push!(non_diag, distance_matrix[i, j])
            end
        end
    end

    if isempty(non_diag)
        return NetworkMetrics(0.0, 0.0, false, 0.0)
    end

    return NetworkMetrics(
        maximum(non_diag),
        mean(non_diag),
        finite_count == total_pairs,
        finite_count / total_pairs,
    )
end

# ----- 链路利用率 -----

"""
    UtilizationResult

链路利用率计算结果。

# 字段
- `avg_utilization::Float64`: 平均利用率 (0-1)
- `max_utilization::Float64`: 最大利用率
- `min_utilization::Float64`: 最小利用率
- `bottleneck_links::Vector{Int}`: 利用率 > 0.8 的链路索引
"""
struct UtilizationResult
    avg_utilization::Float64
    max_utilization::Float64
    min_utilization::Float64
    bottleneck_links::Vector{Int}
end

"""
    compute_link_utilization(used_bandwidth, max_bandwidth) -> UtilizationResult

计算链路利用率。

# 参数
- `used_bandwidth::Vector{Float64}`: 每条链路的已用带宽 (Mbps)
- `max_bandwidth::Vector{Float64}`: 每条链路的最大带宽 (Mbps)

# 返回
`UtilizationResult` — 平均、最大、最小利用率，瓶颈链路
"""
function compute_link_utilization(used_bandwidth::Vector{Float64},
                                   max_bandwidth::Vector{Float64})::UtilizationResult
    length(used_bandwidth) == length(max_bandwidth) || throw(ArgumentError("vectors must have same length"))

    n = length(used_bandwidth)
    n == 0 && return UtilizationResult(0.0, 0.0, 0.0, Int[])

    utilization = [used / max for (used, max) in zip(used_bandwidth, max_bandwidth)]
    bottleneck = findall(u -> u >= 0.8, utilization)

    return UtilizationResult(
        mean(utilization),
        maximum(utilization),
        minimum(utilization),
        bottleneck,
    )
end

# ----- 路由指标（新增）-----

"""
    RoutingMetrics

路由计算结果指标。

# 字段
- `avg_hop_count::Float64`: 平均跳数
- `max_hop_count::Int`: 最大跳数
- `routed_pairs::Int`: 成功路由的 (源, 目的) 对数
- `total_pairs::Int`: 总请求对数
- `success_rate::Float64`: 路由成功率 (0-1)
"""
struct RoutingMetrics
    avg_hop_count::Float64
    max_hop_count::Int
    routed_pairs::Int
    total_pairs::Int
    success_rate::Float64
    uptime_ratio::Float64  # 动态 ISL 激活比例: Nd / (T/2)
end

"""
    compute_routing_metrics(results::Vector{RoutingOutput}) -> RoutingMetrics

从路由结果计算跳数统计和成功率。

# 参数
- `results`: batch_route 的输出列表

# 返回
`RoutingMetrics` — 平均/最大跳数、成功率
"""
function compute_routing_metrics(results::Vector; uptime_ratio::Float64=0.0)::RoutingMetrics
    n_total = length(results)
    n_total == 0 && return RoutingMetrics(0.0, 0, 0, 0, 0.0, uptime_ratio)

    hops = Int[]
    for r in results
        if !isempty(r.path)
            push!(hops, length(r.path) - 1)  # 跳数 = 路径节点数 - 1
        end
    end
    n_routed = length(hops)
    avg_hops = n_routed > 0 ? mean(hops) : 0.0
    max_hops = n_routed > 0 ? maximum(hops) : 0

    return RoutingMetrics(avg_hops, max_hops, n_routed, n_total, n_routed / n_total, uptime_ratio)
end

# ═══════════════════════════════════════════════
# 多帧时序指标
# ═══════════════════════════════════════════════

"""
    TemporalCoverageResult

多帧覆盖分析结果。

# 字段
- `avg_coverage_ratio::Float64`: 平均覆盖率 (每帧覆盖率的均值)
- `max_revisit_gap_s::Float64`: 最大重访间隔（任意地面点无覆盖的最长连续时间, 秒）
- `avg_revisit_gap_s::Float64`: 平均重访间隔
- `handover_count::Int`: 总切换次数（所有地面点的 GSL 切换之和）
- `handover_rate_per_min::Float64`: 每分钟平均切换次数
"""
struct TemporalCoverageResult
    avg_coverage_ratio::Float64
    max_revisit_gap_s::Float64
    avg_revisit_gap_s::Float64
    handover_count::Int
    handover_rate_per_min::Float64
end

"""
    compute_temporal_coverage(gsl_series, dt_s) -> TemporalCoverageResult

从多帧 GSL 可用性序列计算时序覆盖指标。

# 参数
- `gsl_series::Array{Bool,3}`: (N_sat, N_time, N_gs) GSL 可用性
- `dt_s::Float64`: 每帧时间步长 (秒)
"""
function compute_temporal_coverage(gsl_series::Array{Bool,3}, dt_s::Float64)
    N_sat, N_time, N_gs = size(gsl_series)

    # 每帧覆盖率
    frame_ratios = Float64[]
    for t in 1:N_time
        covered = 0
        for g in 1:N_gs
            any(gsl_series[:, t, g]) && (covered += 1)
        end
        push!(frame_ratios, covered / N_gs)
    end
    avg_cov = sum(frame_ratios) / N_time

    # 重访间隔: 每个地面点连续无覆盖的最长帧数
    revisit_gaps = Float64[]
    for g in 1:N_gs
        current_gap = 0.0
        max_gap = 0.0
        for t in 1:N_time
            if any(gsl_series[:, t, g])
                current_gap > 0 && push!(revisit_gaps, current_gap)
                current_gap = 0.0
            else
                current_gap += dt_s
                current_gap > max_gap && (max_gap = current_gap)
            end
        end
        current_gap > 0 && push!(revisit_gaps, current_gap)
    end
    max_revisit = isempty(revisit_gaps) ? 0.0 : maximum(revisit_gaps)
    avg_revisit = isempty(revisit_gaps) ? 0.0 : sum(revisit_gaps) / length(revisit_gaps)

    # 切换次数: GSL 状态变化计数
    ho_count = 0
    for g in 1:N_gs
        for t in 2:N_time
            prev_connected = findfirst(gsl_series[:, t-1, g])
            curr_connected = findfirst(gsl_series[:, t, g])
            # 接入星变化 = 切换
            if prev_connected != curr_connected
                ho_count += 1
            end
        end
    end
    total_minutes = N_time * dt_s / 60.0
    ho_rate = total_minutes > 0 ? ho_count / total_minutes : 0.0

    return TemporalCoverageResult(avg_cov, max_revisit, avg_revisit, ho_count, ho_rate)
end

"""
    compute_handover_frequency(gsl_series, dt_s) -> Float64

计算平均切换频率 (次/分钟)，论文公式(14) 的数值等效。
"""
function compute_handover_frequency(gsl_series::Array{Bool,3}, dt_s::Float64)
    result = compute_temporal_coverage(gsl_series, dt_s)
    return result.handover_rate_per_min
end

"""
    compute_ground_interference(h_km, λ, P_W, G_dBi, J, κ) -> Float64

地面干扰期望值，论文公式(18)。

# 参数
- `h_km::Float64`: 轨道高度 (km)
- `λ::Float64`: 用户密度 (UTs/km²)
- `P_W::Float64`: 用户发射功率 (W)
- `G_dBi::Float64`: 功率增益因子
- `J::Int`: 正交信道数
- `κ::Float64`: 路径损耗指数 (默认 1.98)

# 返回
平均干扰功率 (W)
"""
function compute_ground_interference(;
    h_km::Float64,
    λ::Float64,
    P_W::Float64=2.0,
    G_dBi::Float64=43.5,
    J::Int=1000,
    κ::Float64=1.98,
)
    Re = WGS84_EQUATORIAL_RADIUS_KM  # → Core/L0
    G = 10.0^(G_dBi / 10.0)  # dBi → 线性

    # 公式(16): 最大通信距离
    d_max = sqrt(h_km^2 + 2 * Re * h_km)

    # 公式(18): E(I)
    denom = J * (κ - 2.0) * (Re + h_km)
    term1 = d_max^(2.0 - κ)
    term2 = (2.0 * Re * h_km + h_km^2)^((2.0 - κ) / 2.0)

    E_I = (2π * Re * λ * P_W * G / denom) * (term1 - term2)
    return E_I
end

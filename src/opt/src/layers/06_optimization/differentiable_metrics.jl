# =============================================================================
# Network Metrics — 非可微评估管道
# =============================================================================
# 来源: DifferentiableLEO/src/network/metrics.jl
# 时间平均的网络性能评估：轨道 → 拓扑 → 路由 → 统计。
# 用于快照评估，不涉及 Enzyme 梯度计算。
# =============================================================================

"""
    evaluate_constellation(raans, mas, inc_deg, alt_km, P, SPP;
                           n_time_steps, d_thresh, od_pairs) -> NetworkStats

Full evaluation pipeline averaged over one orbital period.
Float64 only, non-differentiable.
"""
function evaluate_constellation(
    raans::AbstractVector{Float64},    # degrees, length P
    mas::AbstractVector{Float64},      # degrees, length N
    inc_deg::Float64,
    alt_km::Float64,
    P::Int,
    SPP::Int;
    n_time_steps::Int = 120,
    d_thresh::Float64 = 4000.0,
    od_pairs::Vector{Tuple{Int,Int}} = Tuple{Int,Int}[],
)
    N = P * SPP
    inc_rad = inc_deg * π / 180.0
    a = R_EARTH_KM + alt_km
    period_sec = 2π * sqrt(a^3 / MU_KM3_S2)
    time_steps = range(0.0, period_sec; length = n_time_steps)

    all_latencies = Float64[]
    n_unreachable_total = 0
    cp_isl_total = 0
    degree_total = 0.0

    for t_sec in time_steps
        pos = constellation_positions(
            raans, mas, inc_rad, alt_km, t_sec
        )
        A = isl_adjacency(pos, P, SPP; d_thresh = d_thresh)
        lats, n_unr = dijkstra_latency(A; od_pairs)
        append!(all_latencies, lats)
        n_unreachable_total += n_unr
        cp_isl_total += cross_plane_isl_count(pos, P, SPP; d_thresh = d_thresh)
        degrees = [sum(isfinite(A[i, j]) for j in 1:size(A,1) if j != i) for i in 1:N]
        degree_total += sum(degrees) / N
    end

    mean_lat = isempty(all_latencies) ? Inf : sum(all_latencies) / length(all_latencies)
    sorted = sort(all_latencies)
    p95 = isempty(sorted) ? Inf : sorted[min(end, ceil(Int, 0.95 * length(sorted)))]
    p99 = isempty(sorted) ? Inf : sorted[min(end, ceil(Int, 0.99 * length(sorted)))]
    cp_isl_avg = cp_isl_total / n_time_steps
    avg_deg    = degree_total / n_time_steps

    return NetworkStats(mean_lat, p95, p99, n_unreachable_total, round(Int, cp_isl_avg), avg_deg)
end

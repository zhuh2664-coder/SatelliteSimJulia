# ============================================================
# 实验：LEO 星座网络容量口径 + AoN 准入控制
# ============================================================
#
# 研究两个"发表级"补全的效果，产出 CSV 供 plot_study.py 出图：
#
#  研究 1 —— 网络容量的下界/上界夹逼：
#    · greedy（单路径贪心，capacity.jl）= 下界
#    · max-flow（每对单商品最大流，max_flow_capacity.jl）= 上界
#    随星座规模扫描，展示两者差距（多路径可利用的额外容量）。
#
#  研究 2 —— AoN 准入控制 vs 基线：
#    固定星座 + 全球城市 OD 需求，扫描 offered load：
#    · 基线 evaluate_traffic：可达即全额承载 → 链路利用率可 >1（超订）
#    · 容量感知 evaluate_traffic_capacity_aware：瓶颈不足则整条 drop → util ≤ 1
#    对比 承载吞吐 / 最大链路利用率 / 拥塞链路占比 / 阻塞率。
#
# 运行（需 dev 环境含 foundation/orbit/link/metrics/core/net/traffic）：
#   julia --project=<env> experiments/capacity_aon_study/run_study.jl
#
# 输出：experiments/capacity_aon_study/data/{study1_capacity.csv, study2_admission.csv}

using SatelliteSimCore
using SatelliteSimNet
using SatelliteSimTraffic
using SatelliteSimMetrics
using Random
using Printf
import Graphs

const OUTDIR = joinpath(@__DIR__, "data")
isdir(OUTDIR) || mkpath(OUTDIR)

# ---- 全局物理参数 ----
const ISL_CAPACITY_MBPS = 20_000.0   # 研究1：20 Gbps 激光 ISL（容量量级）
const STUDY2_ISL_CAP_MBPS = 2_000.0  # 研究2：设较低使 ISL 成为瓶颈，凸显准入控制
const GSL_CAPACITY_MBPS = 50_000.0   # GSL 设高，使瓶颈落在 ISL（聚焦 ISL 准入）
const PROP = TwoBodyPropagator()

# ────────────────────────────────────────────────────────────
# 工具：构造星座并返回某快照的可用 ISL 图
# ────────────────────────────────────────────────────────────
function snapshot_isl_graph(T::Int, P::Int, F::Int, alt_km::Float64, inc_deg::Float64; t_s::Float64 = 0.0)
    elems = generate_walker_delta(T = T, P = P, F = F, alt_km = alt_km, inc_deg = inc_deg)
    pos = propagate_to_ecef(elems, [t_s]; propagator = PROP)
    snap = pos[:, 1, :]
    topo = generate_topology(GridPlusStrategy(), T, P)
    links = vcat(topo.static_links, topo.dynamic_candidates)
    isl = evaluate_isl_batch(snap, links; constraints = LEO_DEFAULTS)
    edges = Tuple{Int,Int}[]
    for (i, r) in enumerate(isl)
        r.available || continue
        push!(edges, (Int(links[i][1]), Int(links[i][2])))
    end
    g = Graphs.SimpleGraph(T)
    for (u, v) in edges
        u == v && continue
        Graphs.add_edge!(g, u, v)
    end
    return g, edges
end

# 从最大连通分量里采样 OD 对
function sample_pairs_in_giant_component(g::Graphs.SimpleGraph, n_pairs::Int; rng)
    comps = Graphs.connected_components(g)
    isempty(comps) && return Tuple{Int,Int}[], 0
    giant = comps[argmax(length.(comps))]
    length(giant) < 2 && return Tuple{Int,Int}[], length(giant)
    pairs = Tuple{Int,Int}[]
    seen = Set{Tuple{Int,Int}}()
    attempts = 0
    while length(pairs) < n_pairs && attempts < 50 * n_pairs
        attempts += 1
        a = rand(rng, giant); b = rand(rng, giant)
        a == b && continue
        key = a < b ? (a, b) : (b, a)
        key in seen && continue
        push!(seen, key); push!(pairs, key)
    end
    return pairs, length(giant)
end

# ────────────────────────────────────────────────────────────
# 研究 1：容量下界（greedy）vs 上界（max-flow）随规模扫描
# ────────────────────────────────────────────────────────────
function study1()
    println("="^60); println("研究 1：网络容量 下界(greedy) vs 上界(max-flow)"); println("="^60)
    rng = MersenneTwister(20260708)
    # (T, P, F, alt_km, inc_deg)
    configs = [
        (66,  6, 2, 780.0, 86.4),
        (77,  7, 2, 780.0, 86.4),
        (88,  8, 2, 780.0, 86.4),
        (110, 10, 3, 780.0, 86.4),
        (132, 11, 3, 780.0, 86.4),
        (154, 11, 3, 780.0, 86.4),
        (176, 11, 4, 780.0, 86.4),
        (200, 10, 3, 780.0, 86.4),
    ]
    n_pairs = 30
    rows = Tuple{Int,Int,Int,Float64,Float64,Float64}[]  # n_sat, n_giant, n_pairs, greedy, maxflow, ratio
    for (T, P, F, alt, inc) in configs
        g, _ = snapshot_isl_graph(T, P, F, alt, inc)
        n_edges = Graphs.ne(g)
        pairs, giant = sample_pairs_in_giant_component(g, n_pairs; rng = rng)
        if isempty(pairs)
            @printf("  T=%3d  可用 ISL 边=%d  连通分量太小，跳过\n", T, n_edges); continue
        end
        lower = compute_network_capacity(g, pairs; link_capacity_mbps = ISL_CAPACITY_MBPS, step_mbps = 500.0)
        upper = compute_network_capacity_maxflow(g, pairs; link_capacity_mbps = ISL_CAPACITY_MBPS)
        ratio = lower.total_capacity_gbps > 0 ? upper.total_capacity_gbps / lower.total_capacity_gbps : 0.0
        push!(rows, (T, giant, length(pairs), lower.total_capacity_gbps, upper.total_capacity_gbps, ratio))
        @printf("  T=%3d edges=%4d giant=%3d pairs=%2d | greedy=%.1f Gbps  maxflow=%.1f Gbps  上/下=%.2fx\n",
                T, n_edges, giant, length(pairs), lower.total_capacity_gbps, upper.total_capacity_gbps, ratio)
    end
    open(joinpath(OUTDIR, "study1_capacity.csv"), "w") do io
        println(io, "n_sat,n_giant,n_pairs,greedy_gbps,maxflow_gbps,ratio")
        for (ns, ng, np, lo, up, ra) in rows
            @printf(io, "%d,%d,%d,%.4f,%.4f,%.4f\n", ns, ng, np, lo, up, ra)
        end
    end
    println("  → 写出 data/study1_capacity.csv")
    return rows
end

# ────────────────────────────────────────────────────────────
# 研究 2：AoN 准入控制 vs 基线（扫描 offered load）
# ────────────────────────────────────────────────────────────
const CITIES = [
    ("Beijing",   39.9042, 116.4074),
    ("Singapore",  1.3521, 103.8198),
    ("NewYork",   40.7128, -74.0060),
    ("London",    51.5074,  -0.1278),
    ("Tokyo",     35.6762, 139.6503),
    ("Sydney",   -33.8688, 151.2093),
    ("SaoPaulo", -23.5505, -46.6333),
    ("Nairobi",   -1.2921,  36.8219),
]

function build_time_series(T, P, F, alt, inc, tspan)
    elems = generate_walker_delta(T = T, P = P, F = F, alt_km = alt, inc_deg = inc)
    pos = propagate_to_ecef(elems, tspan; propagator = PROP)
    topo = generate_topology(GridPlusStrategy(), T, P)
    links = vcat(topo.static_links, topo.dynamic_candidates)
    isl_pairs = Tuple{Int,Int}[(Int(l[1]), Int(l[2])) for l in links]

    n_time = length(tspan)
    isl_results_by_time = Vector{Vector}(undef, n_time)
    gsl_avail_by_time = Vector{Matrix{Bool}}(undef, n_time)
    gsl_dist_by_time = Vector{Matrix{Float64}}(undef, n_time)
    gsl_elev_by_time = Vector{Matrix{Float64}}(undef, n_time)
    city_coords = [(lat, lon, 0.0) for (_, lat, lon) in CITIES]
    for t in 1:n_time
        snap = pos[:, t, :]
        isl_results_by_time[t] = evaluate_isl_batch(snap, links; constraints = LEO_DEFAULTS)
        gsl_avail, gsl_dist, gsl_elev, _ = evaluate_gsl_batch(snap, city_coords; constraints = LEO_DEFAULTS)
        gsl_avail_by_time[t] = Matrix{Bool}(gsl_avail)
        gsl_dist_by_time[t] = Matrix{Float64}(gsl_dist)
        gsl_elev_by_time[t] = Matrix{Float64}(gsl_elev)
    end
    return pos, isl_pairs, isl_results_by_time, gsl_avail_by_time, gsl_dist_by_time, gsl_elev_by_time
end

# 汇总一个 TrafficEvaluation 的时间平均指标
function summarize(ev)
    offered = 0.0; carried = 0.0; n_assign = 0
    maxutil = 0.0; utilsum = 0.0; nlink = 0; ncong = 0
    for t in 1:length(ev.assignments_by_time)
        for a in ev.assignments_by_time[t]
            offered += a.offered_mbps; carried += a.carried_mbps; n_assign += 1
        end
        for l in ev.link_loads_by_time[t]
            isfinite(l.utilization) || continue
            maxutil = max(maxutil, l.utilization)
            utilsum += l.utilization; nlink += 1
            l.congested && (ncong += 1)
        end
    end
    return (
        offered_gbps = offered / 1000.0,
        carried_gbps = carried / 1000.0,
        blocking = offered > 0 ? (offered - carried) / offered : 0.0,
        maxutil = maxutil,
        meanutil = nlink > 0 ? utilsum / nlink : 0.0,
        congested_frac = nlink > 0 ? ncong / nlink : 0.0,
    )
end

function study2()
    println("="^60); println("研究 2：AoN 准入控制 vs 基线（扫描 offered load）"); println("="^60)
    T, P, F, alt, inc = 400, 20, 7, 780.0, 86.4  # 密集极轨：城市可见率高、OD 全可达
    tspan = collect(0.0:60.0:240.0)             # 5 个快照
    pos, isl_pairs, isl_res, ga, gd, ge = build_time_series(T, P, F, alt, inc, tspan)
    grid = SimulationTimeGrid(default_starlink_simulation_epoch(), Int(tspan[end]), 60)
    ground_ids = collect(1:length(CITIES))
    # 全城市对
    od_pairs = [(i, j) for i in 1:length(CITIES) for j in (i+1):length(CITIES)]

    per_pair_rates = collect(100.0:100.0:2000.0)   # 每对每方向速率 Mbps
    rows = NamedTuple[]
    for rate in per_pair_rates
        demands = TrafficDemand[]
        id = 0
        for (i, j) in od_pairs
            id += 1
            push!(demands, TrafficDemand(id = id, source_ground_id = i, destination_ground_id = j,
                  start_elapsed_s = 0, end_elapsed_s = Int(tspan[end]) + 60, rate_mbps = rate))
        end
        base = evaluate_traffic_from_bare_arrays(pos, isl_pairs, isl_res, ga, gd, ge, ground_ids, grid, demands;
            isl_capacity_mbps = STUDY2_ISL_CAP_MBPS, gsl_capacity_mbps = GSL_CAPACITY_MBPS, capacity_aware = false)
        ca = evaluate_traffic_from_bare_arrays(pos, isl_pairs, isl_res, ga, gd, ge, ground_ids, grid, demands;
            isl_capacity_mbps = STUDY2_ISL_CAP_MBPS, gsl_capacity_mbps = GSL_CAPACITY_MBPS, capacity_aware = true)
        sb = summarize(base); sc = summarize(ca)
        push!(rows, (rate = rate, offered = sb.offered_gbps,
            carried_base = sb.carried_gbps, carried_ca = sc.carried_gbps,
            maxutil_base = sb.maxutil, maxutil_ca = sc.maxutil,
            meanutil_base = sb.meanutil, meanutil_ca = sc.meanutil,
            cong_base = sb.congested_frac, cong_ca = sc.congested_frac,
            block_base = sb.blocking, block_ca = sc.blocking))
        @printf("  rate=%5.0f Mbps | offered=%.1f | carried base=%.1f ca=%.1f Gbps | maxutil base=%.2f ca=%.2f | block base=%.2f ca=%.2f\n",
                rate, sb.offered_gbps, sb.carried_gbps, sc.carried_gbps, sb.maxutil, sc.maxutil, sb.blocking, sc.blocking)
    end
    open(joinpath(OUTDIR, "study2_admission.csv"), "w") do io
        println(io, "rate_mbps,offered_gbps,carried_base_gbps,carried_ca_gbps,maxutil_base,maxutil_ca,meanutil_base,meanutil_ca,congested_frac_base,congested_frac_ca,blocking_base,blocking_ca")
        for r in rows
            @printf(io, "%.1f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f\n",
                r.rate, r.offered, r.carried_base, r.carried_ca, r.maxutil_base, r.maxutil_ca,
                r.meanutil_base, r.meanutil_ca, r.cong_base, r.cong_ca, r.block_base, r.block_ca)
        end
    end
    println("  → 写出 data/study2_admission.csv")
    return rows
end

study1()
println()
study2()
println("\n实验完成。")

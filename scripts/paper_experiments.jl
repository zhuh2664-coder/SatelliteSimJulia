#!/usr/bin/env julia
# =============================================================================
# paper_experiments.jl — 生成论文所需的定量结果与图
# 用法: julia --project=. scripts/paper_experiments.jl
# 产出: paper/figures/*.png  +  paper/data/results.txt
# =============================================================================

using SatelliteSimJulia
using SatelliteSimOpt
using CairoMakie
using Printf
using Statistics
import ForwardDiff

const OPT = SatelliteSimOpt
figdir = joinpath(@__DIR__, "..", "paper", "figures"); mkpath(figdir)
datadir = joinpath(@__DIR__, "..", "paper", "data"); mkpath(datadir)
io = open(joinpath(datadir, "results.txt"), "w")
logboth(s) = (println(s); println(io, s))

logboth("="^70)
logboth("PAPER EXPERIMENTS — SatelliteSimJulia")
logboth("="^70)

# ─────────────────────────────────────────────────────────────────────────────
# Experiment A: 星座规模扫描 —— ISL 可用率 / 连通率 / 平均时延
# ─────────────────────────────────────────────────────────────────────────────
logboth("\n[A] Constellation-scale sweep (P=6 planes, alt=780km, inc=86.4°, +Grid)")
Ts = [24, 48, 66, 72, 96, 132]
P = 6
tspanA = collect(0.0:60.0:60.0)   # 2 帧足够取快照
availA = Float64[]; connA = Float64[]; latA = Float64[]; nislA = Int[]
for T in Ts
    elems = generate_walker_delta(T=T, P=P, F=2, alt_km=780.0, inc_deg=86.4)
    pos = propagate_to_ecef(elems, tspanA; propagator=TwoBodyPropagator())
    topo = generate_topology(GridPlusStrategy(), T, P)
    links = vcat(topo.static_links, topo.dynamic_candidates)
    isl = evaluate_isl_batch(positions_at_last(pos), links; constraints=LEO_DEFAULTS)
    navail = count(r.available for r in isl)
    avail_pct = 100 * navail / max(length(isl), 1)
    avail_pairs = Tuple{Int,Int}[(Int(links[i][1]), Int(links[i][2])) for (i,r) in enumerate(isl) if r.available]
    weights = Float64[r.latency_ms for r in isl if r.available]
    conn_pct = 0.0; avg_lat = NaN
    if !isempty(avail_pairs)
        D = all_pairs_shortest_paths(build_adjacency(T, avail_pairs, weights))
        nfin = 0; noff = T*(T-1)
        s = 0.0; c = 0
        for i in 1:T, j in 1:T
            i == j && continue
            if isfinite(D[i,j]); nfin += 1; s += D[i,j]; c += 1; end
        end
        conn_pct = 100 * nfin / noff
        avg_lat = c > 0 ? s / c : NaN
    end
    push!(availA, avail_pct); push!(connA, conn_pct); push!(latA, avg_lat); push!(nislA, navail)
    @printf(io, "  T=%3d  ISL_avail=%5.1f%% (%d)  conn=%5.1f%%  avg_lat=%6.2f ms\n",
            T, avail_pct, navail, conn_pct, avg_lat)
    @printf("  T=%3d  ISL_avail=%5.1f%% (%d)  conn=%5.1f%%  avg_lat=%6.2f ms\n",
            T, avail_pct, navail, conn_pct, avg_lat)
end

let
    fig = Figure(size=(720, 460))
    ax = Axis(fig[1,1], xlabel="Number of satellites (T, P=6 planes)",
              ylabel="Percentage (%)", title="ISL availability and network connectivity vs constellation size")
    l1 = lines!(ax, Ts, availA; color=:crimson, linewidth=2.5)
    scatter!(ax, Ts, availA; color=:crimson, markersize=10)
    l2 = lines!(ax, Ts, connA; color=:royalblue, linewidth=2.5)
    scatter!(ax, Ts, connA; color=:royalblue, markersize=10)
    axislegend(ax, [l1, l2], ["Available ISL (%)", "Connectivity (%)"]; position=:rc)
    save(joinpath(figdir, "fig_isl_scale.png"), fig)
    logboth("  saved fig_isl_scale.png")
end

# ─────────────────────────────────────────────────────────────────────────────
# Experiment B: 传播器发散 —— TwoBody vs J2（24 小时）
# ─────────────────────────────────────────────────────────────────────────────
logboth("\n[B] Propagator divergence: TwoBody vs J2 (Iridium 66/6, 24h)")
elemsB = generate_walker_delta(T=66, P=6, F=2, alt_km=780.0, inc_deg=86.4)
tspanB = collect(0.0:600.0:86400.0)   # 24h, 10-min steps
posTB = propagate_to_ecef(elemsB, tspanB; propagator=TwoBodyPropagator())
posJ2 = propagate_to_ecef(elemsB, tspanB; propagator=J2Propagator())
hours = tspanB ./ 3600
divmean = Float64[]; divmax = Float64[]
for j in 1:length(tspanB)
    d = [sqrt(sum(abs2, posTB[i,j,:] .- posJ2[i,j,:])) for i in 1:66]
    push!(divmean, mean(d)); push!(divmax, maximum(d))
end
@printf(io, "  divergence @1h: mean=%.1f km; @12h: mean=%.1f km; @24h: mean=%.1f km, max=%.1f km\n",
        divmean[findfirst(>=(1.0), hours)], divmean[findfirst(>=(12.0), hours)], divmean[end], divmax[end])
@printf("  divergence @24h: mean=%.1f km, max=%.1f km\n", divmean[end], divmax[end])
let
    fig = Figure(size=(720, 460))
    ax = Axis(fig[1,1], xlabel="Time (hours)", ylabel="TwoBody vs J2 position difference (km)",
              title="Secular divergence of TwoBody vs J2 propagation (Iridium 66/6)")
    lm = lines!(ax, hours, divmean; color=:seagreen, linewidth=2.5)
    lx = lines!(ax, hours, divmax; color=:orange, linewidth=1.8, linestyle=:dash)
    axislegend(ax, [lm, lx], ["mean over 66 sats", "max over 66 sats"]; position=:lt)
    save(joinpath(figdir, "fig_propagator_divergence.png"), fig)
    logboth("  saved fig_propagator_divergence.png")
end

# ─────────────────────────────────────────────────────────────────────────────
# Experiment C: 端到端梯度校验（Forward / Reverse / 有限差分）
# ─────────────────────────────────────────────────────────────────────────────
logboth("\n[C] End-to-end gradient verification (TLE->SGP4->ISL->soft route loss)")
rep = end_to_end_gradient_report()
@printf(io, "  loss=%.6e  n_params=%d\n", rep.loss, rep.n_params)
@printf(io, "  |grad| forward=%.6e reverse=%.6e fd=%.6e\n",
        rep.grad_forward_norm, rep.grad_reverse_norm, rep.grad_finite_difference_norm)
@printf(io, "  relerr fwd-vs-fd=%.3e  reverse-vs-fwd=%.3e\n",
        rep.max_relerr_forward_vs_fd, rep.max_relerr_reverse_vs_forward)
@printf("  |grad| fwd=%.4e rev=%.4e fd=%.4e; relerr fwd-fd=%.2e rev-fwd=%.2e\n",
        rep.grad_forward_norm, rep.grad_reverse_norm, rep.grad_finite_difference_norm,
        rep.max_relerr_forward_vs_fd, rep.max_relerr_reverse_vs_forward)

# ─────────────────────────────────────────────────────────────────────────────
# Experiment D: 可微覆盖优化收敛（J2 传播 + 软覆盖 + Adam）
# 用项目的 optimize_coverage（内部 Enzyme 反传 + Adam）优化 coverage_loss
# （R1 sigmoid + R2 noisy-OR）。从"单一轨道面"差配置起步，留出优化空间。
# ─────────────────────────────────────────────────────────────────────────────
function run_coverage_opt()
    N = 24
    alt = 780.0; inc = deg2rad(86.4); t0 = 0.0
    gpts, wts = OPT.ground_grid(6, 12; lat_bounds=(-70.0, 70.0))
    gpts = Matrix{Float64}(gpts); wts = Vector{Float64}(wts)
    # Enzyme 在 Float64 值上做反传（非 Dual 类型），三参数同为 Float64，无类型冲突。
    cov_loss = function (params)
        pos3 = reshape(OPT.constellation_positions_j2(params, alt, inc, t0), N, 1, 3)
        return OPT.coverage_loss(pos3, gpts, wts; λ=0.0, min_el=10.0, τ_cov=5.0)
    end
    raan0 = zeros(N)
    ma0 = collect(range(0, 2π, length=N+1))[1:N]
    x0 = vcat(raan0, ma0)
    xopt, rep = optimize_coverage(cov_loss, copy(x0); n_steps=100, lr=0.2)
    return -cov_loss(x0) * 100, -cov_loss(xopt) * 100, rep.loss_history
end

logboth("\n[D] Differentiable coverage optimization (Enzyme + Adam, soft coverage R1/R2)")
init_cov, final_cov, history = run_coverage_opt()
logboth(@sprintf("  init coverage = %.1f%%  final coverage = %.1f%%  (Δ=+%.1f pts, %d steps)",
        init_cov, final_cov, final_cov-init_cov, length(history)))
@printf(io, "  coverage-opt: init=%.1f%%  final=%.1f%%  steps=%d\n", init_cov, final_cov, length(history))
let
    steps = [h[1] for h in history]
    covs = [-h[2]*100 for h in history]
    fig = Figure(size=(720, 460))
    ax = Axis(fig[1,1], xlabel="Adam step", ylabel="Soft global coverage (%)",
              title="Differentiable coverage optimization (24 sats, J2 propagation)")
    lines!(ax, steps, covs; color=:purple, linewidth=2.5)
    hlines!(ax, [init_cov]; color=:gray, linestyle=:dash)
    text!(ax, steps[max(1,length(steps)÷6)], init_cov+1; text="initial", color=:gray, fontsize=12)
    save(joinpath(figdir, "fig_coverage_opt.png"), fig)
    logboth("  saved fig_coverage_opt.png")
end

close(io)
logboth("\n" * "="^70)
logboth("PAPER EXPERIMENTS DONE — see paper/figures/ and paper/data/results.txt")
logboth("="^70)
println("PAPER_EXPERIMENTS_OK")

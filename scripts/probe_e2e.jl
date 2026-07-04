#!/usr/bin/env julia
# 阶段 3+4 主路径端到端冒烟：裸数组主路径数值合理性自检
# generate_walker_delta → propagate_to_ecef → evaluate_isl/gsl_batch

using SatelliteSimJulia
using Printf

println("=" ^ 60)
println("PROBE: 裸数组主路径端到端")
println("=" ^ 60)

# 1. Walker 24/6
elems = generate_walker_delta(T=24, P=6, F=1, alt_km=550.0, inc_deg=53.0)
@printf("[1] walker elems: %d\n", length(elems))

# 2. 传播
tspan = collect(0.0:10.0:100.0)  # 11 步
pos = propagate_to_ecef(elems, tspan; propagator=TwoBodyPropagator())
@printf("[2] pos size: %s  期望 (24,11,3)\n", string(size(pos)))
r1 = sqrt(sum(abs2, pos[1,1,:]))
@printf("    pos[1,1,:] = (%.2f, %.2f, %.2f)\n", pos[1,1,1], pos[1,1,2], pos[1,1,3])
@printf("    |pos[1,1,:]| = %.1f km  (期望 ≈ 6928 = 6378+550)\n", r1)

# 3. 拓扑
topo = generate_topology(GridPlusStrategy(), 24, 6)
links = vcat(topo.static_links, topo.dynamic_candidates)
@printf("[3] topo links: %d (static=%d, dynamic=%d)\n",
    length(links), length(topo.static_links), length(topo.dynamic_candidates))

# 4. ISL 批评估（最后一步）
last_pos = pos[:, end, :]
isl = evaluate_isl_batch(last_pos, links; constraints=LEO_DEFAULTS)
navail = count(r.available for r in isl)
@printf("[4] ISL available: %d / %d\n", navail, length(isl))
# 诊断为何不可用：看距离分布 vs 阈值，看 LOS 分布
dists = [r.distance_km for r in isl]
loses = [r.line_of_sight for r in isl]
@printf("    dist range: min=%.0f max=%.0f mean=%.0f km\n", minimum(dists), maximum(dists), sum(dists)/length(dists))
@printf("    LOS clear: %d / %d\n", count(loses), length(loses))
@printf("    isl_max_range constraint: %.0f km\n", LEO_DEFAULTS.isl_max_range_km)
@printf("    dist > max_range: %d 个\n", count(d .> LEO_DEFAULTS.isl_max_range_km for d in dists))
# 检查仰角/方位角/持续时长约束
elev_ok = count(r.elevation_ok for r in isl)
azim_ok = count(r.azimuth_ok for r in isl)
dur_ok = count(r.duration_ok for r in isl)
@printf("    elevation_ok: %d / %d\n", elev_ok, length(isl))
@printf("    azimuth_ok: %d / %d\n", azim_ok, length(isl))
@printf("    duration_ok: %d / %d\n", dur_ok, length(isl))
# 打印前 5 个 link 的距离/LOS
for i in 1:min(5, length(isl))
    r = isl[i]
    @printf("    link[%d] %s: dist=%.1f km los=%s delay=%.3f ms\n",
        i, r.available ? "OK " : "X  ", r.distance_km, r.line_of_sight, r.latency_ms)
end

# 5. GSL：北京
gsl_avail, gsl_dist, gsl_elev, gsl_delay = evaluate_gsl_batch(last_pos, [(39.9042, 116.4074, 0.0)]; constraints=LEO_DEFAULTS)
nvis = sum(gsl_avail)
@printf("[5] GSL beijing visible sats: %d / 24\n", nvis)
# 打印仰角最高的 3 颗
top3 = sortperm(gsl_elev[:, 1]; rev=true)[1:min(3, end)]
for (k, i) in enumerate(top3)
    @printf("    gsl top%d sat#%d: avail=%s dist=%.1f km elev=%.1f deg\n",
        k, i, gsl_avail[i, 1], gsl_dist[i, 1], gsl_elev[i, 1])
end

# 6. 路由（仅当有可用 ISL 时）
weights = Float64[r.latency_ms for r in isl if r.available]
available_isl = Tuple{Int,Int}[
    (Int(links[i][1]), Int(links[i][2]))
    for (i, r) in enumerate(isl) if r.available
]
if !isempty(available_isl)
    adj = build_adjacency(24, available_isl, weights)
    D = all_pairs_shortest_paths(adj)
    finite = count(isfinite, D)
    @printf("[6] routing D size=%s, finite entries=%d / %d\n", string(size(D)), finite, length(D))
else
    @printf("[6] 无可用 ISL，跳过路由（24/6 星座太稀疏，跨面距离 >5000km 阈值）\n")
end

println("=" ^ 60)
println("PROBE DONE")

# ────────────────────────────────────────────────────────────
# 7. 对比：Iridium 量级 66/6 星座，验证大星座下 ISL 能活
# ────────────────────────────────────────────────────────────
println()
println("=" ^ 60)
println("PROBE-2: Iridium 量级 66/6 星座")
println("=" ^ 60)
elems2 = generate_walker_delta(T=66, P=6, F=2, alt_km=780.0, inc_deg=86.4)
@printf("[1] walker elems: %d\n", length(elems2))
pos2 = propagate_to_ecef(elems2, tspan; propagator=TwoBodyPropagator())
last_pos2 = pos2[:, end, :]
topo2 = generate_topology(GridPlusStrategy(), 66, 6)
links2 = vcat(topo2.static_links, topo2.dynamic_candidates)
isl2 = evaluate_isl_batch(last_pos2, links2; constraints=LEO_DEFAULTS)
navail2 = count(r.available for r in isl2)
dists2 = [r.distance_km for r in isl2]
@printf("[2] ISL available: %d / %d\n", navail2, length(isl2))
@printf("    dist range: min=%.0f max=%.0f mean=%.0f km\n",
    minimum(dists2), maximum(dists2), sum(dists2)/length(dists2))
# 路由
weights2 = Float64[r.latency_ms for r in isl2 if r.available]
available2 = Tuple{Int,Int}[(Int(links2[i][1]), Int(links2[i][2])) for (i,r) in enumerate(isl2) if r.available]
if !isempty(available2)
    adj2 = build_adjacency(66, available2, weights2)
    D2 = all_pairs_shortest_paths(adj2)
    @printf("[3] routing finite entries: %d / %d\n", count(isfinite, D2), length(D2))
    @printf("    D[1,34]=%.2f ms  D[1,60]=%.2f ms\n", D2[1,34], D2[1,60])
end
# GSL 北京 + 新加坡
gsl2 = evaluate_gsl_batch(last_pos2, [(39.9042,116.4074,0.0),(1.3521,103.8198,0.0)]; constraints=LEO_DEFAULTS)
@printf("[4] GSL beijing visible: %d / 66\n", sum(gsl2[1][:,1]))
@printf("    GSL singapore visible: %d / 66\n", sum(gsl2[1][:,2]))
println("=" ^ 60)
println("PROBE-2 DONE")

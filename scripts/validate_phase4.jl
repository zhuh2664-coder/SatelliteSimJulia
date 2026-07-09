# Phase 4 validation harness
#
# 1) Dual-fidelity: analytical prop vs DES underload/overload (Iridium path)
# 2) Queue theory: single-hop DES vs M/D/1
# 3) Orbit cross-check: SatelliteSimOrbit ECI vs GMAT PropSetup (same initial state)
# 4) Export ns-3 scenario JSON for external comparison
#
# Usage (from repo root):
#   julia --project=. scripts/validate_phase4.jl

using SatelliteSimJulia
using GMAT
using LinearAlgebra
using Printf
using Statistics

const OUT_DIR = joinpath(@__DIR__, "..", "data", "validation")
mkpath(OUT_DIR)

println("="^64)
println("Phase 4 — dual fidelity + validation baselines")
println("="^64)

# ── 1. Build a real analytical path (Iridium-like) ─────────────────
println("\n[1] Analytical constellation → Dijkstra path")
elems = generate_walker_delta(T=66, P=6, F=2, alt_km=780.0, inc_deg=86.4)
pos = propagate_to_ecef(elems, [0.0, 60.0])
topo = generate_topology(GridPlusStrategy(), 66, 6)
links = vcat(topo.static_links, topo.dynamic_candidates)
isl = evaluate_isl_batch(positions_at_last(pos), links; constraints=LEO_DEFAULTS)
avail = [(Int(links[i][1]), Int(links[i][2])) for (i, r) in enumerate(isl) if r.available]
wlat = Float64[r.latency_ms for r in isl if r.available]

adj = Dict{Int,Vector{Tuple{Int,Float64}}}()
for (k, (a, b)) in enumerate(avail)
    push!(get!(adj, a, Tuple{Int,Float64}[]), (b, wlat[k]))
    push!(get!(adj, b, Tuple{Int,Float64}[]), (a, wlat[k]))
end

function dijkstra_path(adj, s, t)
    dist = Dict(s => 0.0)
    prev = Dict{Int,Int}()
    vis = Set{Int}()
    while true
        cur = nothing
        cd = Inf
        for (n, d) in dist
            if !(n in vis) && d < cd
                cur = n; cd = d
            end
        end
        cur === nothing && return nothing
        cur == t && break
        push!(vis, cur)
        for (nb, w) in get(adj, cur, Tuple{Int,Float64}[])
            nb in vis && continue
            nd = cd + w
            if nd < get(dist, nb, Inf)
                dist[nb] = nd
                prev[nb] = cur
            end
        end
    end
    path = [t]
    c = t
    while c != s
        haskey(prev, c) || return nothing
        c = prev[c]
        pushfirst!(path, c)
    end
    hop = Float64[]
    for i in 1:length(path)-1
        for (nb, w) in adj[path[i]]
            if nb == path[i+1]
                push!(hop, w); break
            end
        end
    end
    return path, hop
end

src_sat, dst_sat = 1, 34
pr = dijkstra_path(adj, src_sat, dst_sat)
pr === nothing && error("no path $src_sat → $dst_sat")
path, hop_ms = pr
@printf("path %d→%d: %d hops  prop=%.3f ms\n", src_sat, dst_sat, length(hop_ms), sum(hop_ms))

# ── 2. Dual fidelity ───────────────────────────────────────────────
println("\n[2] Dual fidelity (analytical vs DES)")
df = compare_path_fidelity(hop_ms, 100e6; duration_s=0.5, seed=42)
@printf("analytical prop     : %.3f ms\n", df.analytical_prop_ms)
@printf("DES underload mean  : %.3f ms  drops=%d  aligned=%s\n",
        df.underload.mean_latency_ms, df.underload.n_dropped, string(df.aligned))
@printf("DES overload mean   : %.3f ms  drop=%.2f%%  queue=%.3f ms\n",
        df.overload.mean_latency_ms, 100 * df.overload_drop_ratio, df.overload_queue_ms)
df.aligned || @warn "underload DES not aligned with analytical+tx — check seed/duration"

# ── 3. M/D/1 theory baseline ───────────────────────────────────────
println("\n[3] M/D/1 theory vs single-hop DES")
md = compare_to_md1(10.0, 100e6; load_frac=0.7, duration_s=2.0, seed=1)
@printf("ρ=%.2f  theory Wq=%.4f ms  DES Wq=%.4f ms  rel_err=%.1f%%  ok=%s\n",
        md.rho, 1000 * md.theory_wait_s, 1000 * md.des_queue_s,
        100 * md.rel_error, string(md.within_tol))

# ── 4. Export ns-3 scenario ────────────────────────────────────────
println("\n[4] Export ns-3 scenario JSON")
sc = Ns3Scenario(
    "iridium_1_to_34_overload",
    hop_ms,
    100e6,
    1500,
    130e6,
    2.0,
    32,
    42,
)
ns3_path = joinpath(OUT_DIR, "ns3_scenario_iridium.json")
export_ns3_scenario(ns3_path, sc)
println("wrote ", ns3_path)

# ── 5. Orbit: ECI TwoBody/J2 vs GMAT (same initial circular state) ─
println("\n[5] Orbit cross-check: propagate_positions (ECI) vs GMAT PropSetup")
R_E = 6378.137e3
alt = 780e3
μ = 3.986004418e14
a = R_E + alt
v_circ = sqrt(μ / a)
r0 = [a, 0.0, 0.0]
v0 = [0.0, v_circ, 0.0]
tspan = collect(0.0:60.0:600.0)

# Matching near-circular Keplerian via Walker helper (abstract Vector{KeplerianElements})
els = generate_walker_delta(T=1, P=1, F=0, alt_km=780.0, inc_deg=0.0)
# Align GMAT initial state to Orbit package's first ECI sample (meters)
pos0 = propagate_positions(els, [0.0]; propagator=:two_body)  # km
r0 = pos0[1, 1, :] .* 1000
# circular equatorial velocity perpendicular to r
v0 = [-r0[2], r0[1], 0.0]
v0 = v0 .* (v_circ / max(norm(v0), eps()))
pos_tb = propagate_positions(els, tspan; propagator=:two_body)  # km
pos_j2 = propagate_positions(els, tspan; propagator=:j2)

setup = PropSetup(
    force_model=combine_forces(GravityField(degree=2)),
    integrator=PrinceDormand78(),
    spacecraft=Spacecraft(),
)
sol = propagate(setup, vcat(r0, v0), tspan)
gmat_km = zeros(1, length(tspan), 3)
for (k, u) in enumerate(sol.u)
    gmat_km[1, k, :] .= u[1:3] ./ 1000
end

n = min(size(pos_j2, 2), size(gmat_km, 2), size(pos_tb, 2))
err_j2 = [norm(pos_j2[1, k, :] .- gmat_km[1, k, :]) * 1000 for k in 1:n]  # m
err_tb = [norm(pos_tb[1, k, :] .- gmat_km[1, k, :]) * 1000 for k in 1:n]
drift_tb_j2 = [norm(pos_tb[1, k, :] .- pos_j2[1, k, :]) * 1000 for k in 1:n]
@printf("GMAT(J2) vs Orbit-J2 : mean|Δr|=%.1f m  max=%.1f m\n", mean(err_j2), maximum(err_j2))
@printf("GMAT(J2) vs Orbit-TB : mean|Δr|=%.1f m  max=%.1f m\n", mean(err_tb), maximum(err_tb))
@printf("Orbit TwoBody vs J2  : mean|Δr|=%.1f m  max=%.1f m\n", mean(drift_tb_j2), maximum(drift_tb_j2))

# ── 6. Write summary report ────────────────────────────────────────
report = joinpath(OUT_DIR, "phase4_report.txt")
open(report, "w") do io
    println(io, "SatelliteSimJulia Phase 4 validation report")
    println(io, "path: ", path)
    @printf(io, "analytical_prop_ms=%.6f\n", df.analytical_prop_ms)
    @printf(io, "des_underload_mean_ms=%.6f drops=%d aligned=%s\n",
            df.underload.mean_latency_ms, df.underload.n_dropped, string(df.aligned))
    @printf(io, "des_overload_mean_ms=%.6f drop_ratio=%.6f queue_ms=%.6f\n",
            df.overload.mean_latency_ms, df.overload_drop_ratio, df.overload_queue_ms)
    @printf(io, "md1_rho=%.4f theory_ms=%.6f des_ms=%.6f rel_err=%.4f ok=%s\n",
            md.rho, 1000 * md.theory_wait_s, 1000 * md.des_queue_s, md.rel_error, string(md.within_tol))
    @printf(io, "gmat_vs_j2_mean_m=%.6f max_m=%.6f\n", mean(err_j2), maximum(err_j2))
    @printf(io, "orbit_tb_vs_j2_mean_m=%.6f\n", mean(drift_tb_j2))
    println(io, "ns3_scenario=", ns3_path)
end
println("\nwrote ", report)
println("="^64)
println("Phase 4 validation done.")
@printf("aligned=%s  md1_ok=%s  gmat_vs_j2_mean_m=%.1f\n",
        string(df.aligned), string(md.within_tol), mean(err_j2))

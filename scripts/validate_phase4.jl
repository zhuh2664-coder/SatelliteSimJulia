# Phase 4 validation harness
#
# 1) Dual-fidelity: analytical prop vs DES underload/overload (Iridium path)
# 2) Queue theory: single-hop DES vs M/D/1
# 3) Orbit cross-check: SatelliteSimOrbit ECI vs GMAT PropSetup (true initial RV)
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

# ── 5. Orbit: true ECI RV vs GMAT ──────────────────────────────────
println("\n[5] Orbit cross-check: propagate_eci_rv vs GMAT PropSetup")
els = generate_walker_delta(T=1, P=1, F=0, alt_km=780.0, inc_deg=0.0)
tspan = collect(0.0:60.0:600.0)

pos_tb, vel_tb = propagate_eci_rv(els, tspan; propagator=:two_body)  # m, m/s
pos_j2, vel_j2 = propagate_eci_rv(els, tspan; propagator=:j2)

r0 = pos_tb[1, 1, :]
v0 = vel_tb[1, 1, :]
@printf("initial |r|=%.3f km  |v|=%.3f m/s  (NOT circular √(μ/a))\n",
        norm(r0) / 1000, norm(v0))

setup_kepler = PropSetup(
    force_model=combine_forces(GravityField(degree=0)),
    integrator=PrinceDormand78(),
    spacecraft=Spacecraft(),
)
setup_j2 = PropSetup(
    force_model=combine_forces(GravityField(degree=2)),
    integrator=PrinceDormand78(),
    spacecraft=Spacecraft(),
)
sol_k = propagate(setup_kepler, vcat(r0, v0), tspan)
sol_j = propagate(setup_j2, vcat(r0, v0), tspan)

n = length(tspan)
err_kepler = [norm(sol_k.u[k][1:3] .- pos_tb[1, k, :]) for k in 1:n]
err_j2 = [norm(sol_j.u[k][1:3] .- pos_j2[1, k, :]) for k in 1:n]
drift_tb_j2 = [norm(pos_tb[1, k, :] .- pos_j2[1, k, :]) for k in 1:n]

@printf("GMAT Kepler vs Orbit-TB : mean|Δr|=%.3f m  max=%.3f m  (gate: ~0)\n",
        mean(err_kepler), maximum(err_kepler))
@printf("GMAT J2 vs Orbit-J2     : mean|Δr|=%.1f m  max=%.1f m  (baseline; model form differs)\n",
        mean(err_j2), maximum(err_j2))
@printf("Orbit TwoBody vs J2     : mean|Δr|=%.1f m  max=%.1f m\n",
        mean(drift_tb_j2), maximum(drift_tb_j2))

kepler_ok = maximum(err_kepler) < 1.0  # sub-meter over 10 min
kepler_ok || @warn "Kepler cross-check failed — check initial RV / μ constants"

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
    @printf(io, "gmat_kepler_vs_tb_mean_m=%.6f max_m=%.6f ok=%s\n",
            mean(err_kepler), maximum(err_kepler), string(kepler_ok))
    @printf(io, "gmat_j2_vs_orbit_j2_mean_m=%.6f max_m=%.6f\n", mean(err_j2), maximum(err_j2))
    @printf(io, "orbit_tb_vs_j2_mean_m=%.6f\n", mean(drift_tb_j2))
    println(io, "ns3_scenario=", ns3_path)
end
println("\nwrote ", report)
println("="^64)
println("Phase 4 validation done.")
@printf("aligned=%s  md1_ok=%s  gmat_kepler_ok=%s  gmat_j2_mean_m=%.1f\n",
        string(df.aligned), string(md.within_tol), string(kepler_ok), mean(err_j2))

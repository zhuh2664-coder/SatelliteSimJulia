# Bridge demo: analytical constellation/ISL → packet-level DES
#
# Usage (from repo root):
#   julia --project=. scripts/demo_netsim_bridge.jl

using SatelliteSimLink
using SatelliteSimNet
using SatelliteSimNetSim
using SatelliteSimOrbit
using Printf

println("【解析层】Iridium 66/6 → ISL → Dijkstra 路径")
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
                cur = n
                cd = d
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
                push!(hop, w)
                break
            end
        end
    end
    return path, hop
end

src_sat, dst_sat = 1, 34
pr = dijkstra_path(adj, src_sat, dst_sat)
pr === nothing && error("no path $src_sat → $dst_sat")
path, hop_ms = pr

@printf("path %d→%d: %d hops  %s\n", src_sat, dst_sat, length(hop_ms), string(path))
@printf("analytical prop delay: %.3f ms\n", sum(hop_ms))

println("\n【DES 层】SatelliteSimNetSim.simulate_path (130 Mbps over 100 Mbps)")
result = simulate_path(
    hop_ms,
    100e6;
    load_bps=130e6,
    duration_s=2.0,
    poisson=true,
    seed=42,
    max_packets=32,
)

@printf("sent/deliv/drop: %d / %d / %d  (drop %.2f%%)\n",
        result.n_sent, result.n_delivered, result.n_dropped, 100 * result.drop_ratio)
@printf("e2e latency: mean %.3f | p95 %.3f | max %.3f ms\n",
        result.mean_latency_ms, result.p95_latency_ms, result.max_latency_ms)
@printf("queue delay: %.3f ms  (analytical layer cannot see this)\n", result.mean_queue_delay_ms)
@printf("hop drops: %s\n", string(result.hop_drops))
println("done.")

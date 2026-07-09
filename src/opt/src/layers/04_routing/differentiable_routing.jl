# =============================================================================
# Layer 3 — Routing and Traffic (Pure Julia Dijkstra)
# =============================================================================
# 来源: DifferentiableLEO/src/network/routing.jl
# 提供纯 Julia O(N²) Dijkstra + AON 吞吐量 + NetworkStats。
# 与主项目的 DijkstraRouting 互补：本实现直接操作邻接矩阵，适合与
# isl_adjacency() 的 Matrix{Float64} 输出对接。
# =============================================================================

const SPEED_OF_LIGHT_KMS = SatelliteSimFoundation.SPEED_OF_LIGHT_KM_S  # → Foundation/L0

export NetworkStats, dijkstra_latency, aon_throughput, network_stats

"""
    NetworkStats

Summary statistics for a constellation snapshot.
"""
struct NetworkStats
    mean_latency_ms :: Float64
    p95_latency_ms  :: Float64
    p99_latency_ms  :: Float64
    unreachable     :: Int
    cross_plane_isl :: Int
    avg_degree      :: Float64
end

# ── Pure Julia Dijkstra ───────────────────────────────────────────────────────

"""
    _dijkstra(A, src) -> dist_km

Single-source shortest paths using O(N²) Dijkstra.
"""
function _dijkstra(A::AbstractMatrix{Float64}, src::Int)
    N = size(A, 1)
    dist    = fill(Inf, N)
    visited = falses(N)
    dist[src] = 0.0

    for _ in 1:N
        u = 0
        d_min = Inf
        for i in 1:N
            if !visited[i] && dist[i] < d_min
                u = i
                d_min = dist[i]
            end
        end
        u == 0 && break
        visited[u] = true

        for v in 1:N
            if !visited[v] && isfinite(A[u, v])
                nd = dist[u] + A[u, v]
                if nd < dist[v]
                    dist[v] = nd
                end
            end
        end
    end
    return dist
end

function _dijkstra_with_prev(A::AbstractMatrix{Float64}, src::Int)
    N = size(A, 1)
    dist = fill(Inf, N)
    prev = zeros(Int, N)
    visited = falses(N)
    dist[src] = 0.0

    for _ in 1:N
        u = 0
        d_min = Inf
        for i in 1:N
            if !visited[i] && dist[i] < d_min
                u = i
                d_min = dist[i]
            end
        end
        u == 0 && break
        visited[u] = true

        for v in 1:N
            if !visited[v] && isfinite(A[u, v])
                nd = dist[u] + A[u, v]
                if nd < dist[v]
                    dist[v] = nd
                    prev[v] = u
                end
            end
        end
    end
    return dist, prev
end

function _path_from_prev(prev::Vector{Int}, src::Int, dst::Int)
    path = Int[]
    v = dst
    while v != 0
        push!(path, v)
        v == src && break
        v = prev[v]
        v == 0 && return Int[]
    end
    return reverse(path)
end

# ── Public API ────────────────────────────────────────────────────────────────

"""
    dijkstra_latency(A; od_pairs) -> (latencies_ms, n_unreachable)

Compute end-to-end latencies (ms) for OD pairs via Dijkstra.
"""
function dijkstra_latency(
    A::AbstractMatrix{Float64};
    od_pairs::Vector{Tuple{Int,Int}} = Tuple{Int,Int}[],
)
    N = size(A, 1)
    if isempty(od_pairs)
        od_pairs = [(i, j) for i in 1:N for j in (i + 1):N]
    end

    latencies    = Float64[]
    n_unreachable = 0

    for src in unique(first.(od_pairs))
        dists = _dijkstra(A, src)
        for (s, d) in od_pairs
            s != src && continue
            if isinf(dists[d])
                n_unreachable += 1
            else
                push!(latencies, dists[d] / SPEED_OF_LIGHT_KMS * 1000.0)  # km → ms
            end
        end
    end
    return latencies, n_unreachable
end

"""
    aon_throughput(A, capacity_gbps; n_od_samples) -> (throughput_ratio, n_overloaded)

All-Or-Nothing traffic: each OD pair sends 1 unit on its shortest path.
"""
function aon_throughput(
    A::AbstractMatrix{Float64},
    capacity_gbps::Float64 = 10.0;
    n_od_samples::Int = 500,
)
    N = size(A, 1)
    all_pairs = [(i, j) for i in 1:N for j in (i + 1):N]
    od_pairs  = length(all_pairs) > n_od_samples ?
                all_pairs[round.(Int, range(1, length(all_pairs); length = n_od_samples))] :
                all_pairs

    link_load = Dict{Tuple{Int,Int}, Float64}()
    served = 0

    for src in unique(first.(od_pairs))
        dists, prev = _dijkstra_with_prev(A, src)
        for (s, d) in od_pairs
            s != src && continue
            isinf(dists[d]) && continue
            served += 1
            path = _path_from_prev(prev, s, d)
            for k in 2:length(path)
                u, v = path[k - 1], path[k]
                edge = u < v ? (u, v) : (v, u)
                link_load[edge] = get(link_load, edge, 0.0) + 1.0
            end
        end
    end

    n_overloaded = count(v -> v > capacity_gbps, values(link_load))
    return served / length(od_pairs), n_overloaded
end

"""
    network_stats(A, P, SPP; od_pairs) -> NetworkStats
"""
function network_stats(
    A::AbstractMatrix{Float64},
    P::Int,
    SPP::Int;
    od_pairs::Vector{Tuple{Int,Int}} = Tuple{Int,Int}[],
) :: NetworkStats
    N = P * SPP
    latencies, n_unreachable = dijkstra_latency(A; od_pairs)

    mean_lat = isempty(latencies) ? Inf : sum(latencies) / length(latencies)
    sorted   = sort(latencies)
    p95 = isempty(sorted) ? Inf : sorted[min(end, ceil(Int, 0.95 * length(sorted)))]
    p99 = isempty(sorted) ? Inf : sorted[min(end, ceil(Int, 0.99 * length(sorted)))]

    cp_isl = sum(
        isfinite(A[i, j]) && (i - 1) ÷ SPP != (j - 1) ÷ SPP
        for i in 1:N for j in (i + 1):N
    )
    degrees = [count(j -> isfinite(A[i, j]) && j != i, 1:N) for i in 1:N]
    avg_deg = sum(degrees) / N

    return NetworkStats(mean_lat, p95, p99, n_unreachable, cp_isl, avg_deg)
end

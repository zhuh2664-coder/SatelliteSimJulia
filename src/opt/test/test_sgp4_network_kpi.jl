# =============================================================================
# Tests for the differentiable network-KPI chain
#   TLE params θ → SGP4 ECEF series (N,NT,3) → {soft latency, reachability, λ₂}
# =============================================================================
# Acceptance goals (from the Step-3 plan):
#   (1) KPI differentiable in positions — ForwardDiff-on-P vs central FD < 1e-6.
#   (2) End-to-end θ→KPI gradient (blockdiag / whole-chain Enzyme) vs full
#       ForwardDiff < 1e-6 (latency, N=10 real Starlink TLE).
#   (3) Boundary / domain errors.
# Plus soft↔hard reference checks (Dijkstra latency & reachability, exact λ₂).

using Test
using Random
using LinearAlgebra: norm, dot, eigvals, Symmetric, Diagonal
using ForwardDiff
using SatelliteToolbox
using SatelliteToolboxSgp4
import SatelliteSimOpt
using SatelliteSimOpt: soft_isl_adjacency, soft_isl_edge_weights, soft_los_factor,
                       hard_isl_adjacency, soft_expected_latency_ms,
                       soft_reachability_ratio, soft_algebraic_connectivity,
                       network_kpi_loss, network_kpi_config, default_od_pairs,
                       network_kpi_loss_grad_positions, soft_connectivity_loss_vjp,
                       sgp4_network_kpi_gradient, sgp4_constellation_series, sgp4_series_ecef,
                       dijkstra_latency

const NK_D2R = π / 180
const NK_REV_DAY_TO_RAD_MIN = 2π / (24 * 60)
const NK_TLE_PATH = joinpath(@__DIR__, "..", "..", "..",
                             "data", "tle", "celestrak", "starlink_gp_latest.tle")

function nk_read_params_epochs(n::Int)
    lines = readlines(NK_TLE_PATH)
    tles = SatelliteToolboxSgp4.TLE[]
    for i in 1:n
        push!(tles, SatelliteToolboxSgp4.read_tle(strip(lines[3i-1]), strip(lines[3i]);
                                                  verify_checksum=false))
    end
    epochs = Float64[SatelliteToolboxSgp4.tle_epoch(t) for t in tles]
    params = Float64[]
    for t in tles
        append!(params, (t.mean_motion * NK_REV_DAY_TO_RAD_MIN, t.eccentricity,
                         t.inclination * NK_D2R, t.raan * NK_D2R,
                         t.argument_of_perigee * NK_D2R, t.mean_anomaly * NK_D2R, t.bstar))
    end
    return params, epochs
end

# Deterministic random-geometric constellation on a spherical shell (good gap).
function nk_synth_positions(N, NT; R=6921.0, drift=0.02)
    P = zeros(N, NT, 3)
    for t in 1:NT, i in 1:N
        z = 2*(i-0.5)/N - 1; r = sqrt(1 - z^2); θ = 2π*0.6180339887*i + drift*(t-1)
        P[i,t,1] = R*r*cos(θ); P[i,t,2] = R*r*sin(θ); P[i,t,3] = R*z
    end
    return P
end

nk_param_class_groups(N::Int) = [collect(c:7:(7N)) for c in 1:7]

@testset "SGP4 → network KPI differentiable chain" begin

# ── exports ──────────────────────────────────────────────────────────────────
@testset "public API is exported" begin
    for s in (:soft_isl_adjacency, :soft_isl_edge_weights, :hard_isl_adjacency,
              :soft_expected_latency_ms, :soft_reachability_ratio,
              :soft_algebraic_connectivity, :network_kpi_loss,
              :soft_connectivity_loss_vjp, :sgp4_network_kpi_gradient)
        @test s in names(SatelliteSimOpt)
    end
end

# ── general soft adjacency: shape, range, symmetry, hard limit ────────────────
@testset "soft_isl_adjacency structure and hard limit" begin
    P = nk_synth_positions(10, 1)
    Pt = P[:, 1, :]
    A = soft_isl_adjacency(Pt; d_thresh=9000.0, τ=200.0)
    @test size(A) == (10, 10)
    @test all(0 .<= A .<= 1)
    @test A ≈ A'
    @test all(iszero, [A[i, i] for i in 1:10])

    # τ → 0 recovers the hard range test d_ij < d_thresh
    Ahard = soft_isl_adjacency(Pt; d_thresh=9000.0, τ=1e-2)
    for i in 1:10, j in 1:10
        i == j && continue
        d = norm(Pt[i, :] .- Pt[j, :])
        @test Ahard[i, j] ≈ (d < 9000.0 ? 1.0 : 0.0) atol=1e-6
    end

    # LOS factor is in (0,1]; blocked pair (antipodal, chord through Earth) → ~0
    los_clear = soft_los_factor(7000.0, 0.0, 0.0, 7000.0, 500.0, 0.0)      # nearby
    los_block = soft_los_factor(7000.0, 0.0, 0.0, -7000.0, 0.0, 0.0)       # through core
    @test 0 < los_clear <= 1
    @test los_block < 1e-3
    @test los_clear > los_block
end

# ── AbstractArray view support on public forward APIs ─────────────────────────
@testset "public forward APIs accept AbstractArray views" begin
    # Position-series KPI APIs are typed as AbstractArray and should accept views.
    Pfull = nk_synth_positions(9, 3)
    Pview = @view Pfull[2:8, :, :]
    od = default_od_pairs(size(Pview, 1); count=3)
    kw = (d_thresh=9000.0, τ=250.0, τsp=60.0, bellman_K=size(Pview, 1), penalty_km=5.0e5)

    @test soft_expected_latency_ms(Pview; od_pairs=od, kw...) ≈
          soft_expected_latency_ms(Array(Pview); od_pairs=od, kw...) rtol=1e-12
    @test soft_reachability_ratio(Pview; od_pairs=od, kw...) ≈
          soft_reachability_ratio(Array(Pview); od_pairs=od, kw...) rtol=1e-12
    @test soft_algebraic_connectivity(Pview; d_thresh=9000.0, τ=250.0, fiedler_K=400) ≈
          soft_algebraic_connectivity(Array(Pview); d_thresh=9000.0, τ=250.0, fiedler_K=400) rtol=1e-12
    @test network_kpi_loss(Pview; kind=:latency, od_pairs=od, kw...) ≈
          network_kpi_loss(Array(Pview); kind=:latency, od_pairs=od, kw...) rtol=1e-12

    # SGP4 forward series APIs also accept parameter views.
    params, epochs = nk_read_params_epochs(2)
    pview = @view params[:]
    ts_min = [0.0, 30.0, 60.0]
    jd_ref = maximum(epochs)
    gmsts = Float64[SatelliteToolbox.jd_to_gmst(jd_ref + t / 1440.0) for t in ts_min]
    @test sgp4_constellation_series(pview, epochs, ts_min; jd_ref=jd_ref) ≈
          sgp4_constellation_series(params, epochs, ts_min; jd_ref=jd_ref) rtol=0 atol=0
    @test sgp4_series_ecef(pview, epochs, ts_min, gmsts; jd_ref=jd_ref) ≈
          sgp4_series_ecef(params, epochs, ts_min, gmsts; jd_ref=jd_ref) rtol=0 atol=0

    # Known blocker: Enzyme Duplicated currently requires primal/tangent to share
    # the same SubArray type, so this reverse-mode API does not accept views yet.
    cfg = network_kpi_config(size(Pview, 1), size(Pview, 2); kind=:latency, od_pairs=od, kw...)
    @test_throws MethodError network_kpi_loss_grad_positions(Pview, cfg)
end

# ── (1) KPI differentiable in positions: ForwardDiff-on-P vs central FD < 1e-6 ─
@testset "KPI vs central finite differences on positions (< 1e-6)" begin
    P = nk_synth_positions(8, 2)
    od = default_od_pairs(8; count=4)
    kw = (d_thresh=9000.0, τ=250.0, τsp=60.0, bellman_K=8, penalty_km=5.0e5)

    for (name, lossfn) in (
        ("latency", Q -> network_kpi_loss(Q; kind=:latency, od_pairs=od, kw...)),
        ("reachability", Q -> network_kpi_loss(Q; kind=:reachability, od_pairs=od, kw...)),
    )
        @testset "$name" begin
            g_ad = ForwardDiff.gradient(lossfn, P)
            @test all(isfinite, g_ad)
            gmax = maximum(abs, g_ad)
            @test gmax > 0
            flat = vec(P)
            worst = 0.0
            for idx in eachindex(flat)
                abs(g_ad[idx]) < 1e-3 * gmax && continue   # skip near-zero comps
                h0 = 1e-4 * max(abs(flat[idx]), 1.0)
                best = Inf
                for sc in (0.1, 1.0, 10.0)
                    h = sc * h0
                    xp = copy(flat); xm = copy(flat); xp[idx] += h; xm[idx] -= h
                    gp = lossfn(reshape(xp, size(P)...))
                    gm = lossfn(reshape(xm, size(P)...))
                    best = min(best, abs(g_ad[idx] - (gp - gm) / (2h)) /
                                     (abs((gp - gm) / (2h)) + 1e-10 * gmax))
                end
                worst = max(worst, best)
            end
            @test worst < 1e-6
        end
    end
end

# ── Enzyme dL/dP vs ForwardDiff on positions (latency) ───────────────────────
@testset "Enzyme dL/dP matches ForwardDiff on positions (latency)" begin
    P = nk_synth_positions(8, 2)
    od = default_od_pairs(8; count=4)
    cfg = network_kpi_config(8, 2; kind=:latency, od_pairs=od,
                             d_thresh=9000.0, τ=250.0, τsp=60.0, bellman_K=8)
    loss_e, dP_e = network_kpi_loss_grad_positions(P, cfg)
    g_fd = ForwardDiff.gradient(Q -> network_kpi_loss(Q; kind=:latency, od_pairs=od,
                                d_thresh=9000.0, τ=250.0, τsp=60.0, bellman_K=8), P)
    @test loss_e ≈ network_kpi_loss(P; kind=:latency, od_pairs=od,
                                    d_thresh=9000.0, τ=250.0, τsp=60.0, bellman_K=8) rtol=1e-12
    @test norm(dP_e - g_fd) / norm(g_fd) < 1e-10
end

# ── connectivity: perturbation VJP vs central FD of the EXACT λ₂ (eigvals) ────
# The eigenvalue-perturbation gradient ∂λ₂/∂A=(vᵢ−vⱼ)² is only well-defined when
# λ₂ is simple (a well-separated Fiedler mode). We therefore use an open-arc
# "path graph" geometry (consecutive links only), whose low spectrum is simple
# and well-separated, and assert the spectral gap so the condition is explicit.
@testset "connectivity VJP vs finite-difference of exact λ₂ (gapped graph)" begin
    N, NT = 8, 1
    R = 6921.0
    P = zeros(N, NT, 3)
    for i in 1:N
        θ = 0.5 * (i - 1)                 # open arc → path-graph adjacency
        P[i, 1, 1] = R * cos(θ); P[i, 1, 2] = R * sin(θ); P[i, 1, 3] = 0.0
    end
    dth, τ = 5000.0, 200.0

    function exact_lambda2(flat)
        Pm = reshape(flat, N, NT, 3)
        A = soft_isl_adjacency(Pm[:, 1, :]; d_thresh=dth, τ=τ)
        d = vec(sum(A; dims=2))
        L = Diagonal(d) - A
        return sort(eigvals(Symmetric(Matrix(L))))[2]
    end
    A0 = soft_isl_adjacency(P[:, 1, :]; d_thresh=dth, τ=τ)
    ev = sort(eigvals(Symmetric(Matrix(Diagonal(vec(sum(A0; dims=2))) - A0))))
    @test (ev[3] - ev[2]) / ev[2] > 1.0   # simple, well-separated λ₂

    cfg = network_kpi_config(N, NT; kind=:connectivity, d_thresh=dth, τ=τ, fiedler_K=1500)
    loss_v, dP_v = soft_connectivity_loss_vjp(P, cfg)
    @test loss_v < 0                      # -λ₂ < 0

    flat = vec(P)
    g_true = similar(flat)
    for i in eachindex(flat)
        h = 1e-4 * max(abs(flat[i]), 1.0)
        xp = copy(flat); xm = copy(flat); xp[i] += h; xm[i] -= h
        g_true[i] = -(exact_lambda2(xp) - exact_lambda2(xm)) / (2h)   # grad of -λ₂
    end
    @test norm(vec(dP_v) - g_true) / (norm(g_true) + 1e-12) < 1e-3
end

# ── (2) end-to-end θ→KPI: blockdiag & Enzyme vs full ForwardDiff (< 1e-6) ─────
@testset "end-to-end latency gradient vs full ForwardDiff (N=10, both engines)" begin
    N, NT = 10, 5
    params, epochs = nk_read_params_epochs(N)
    jd_ref = maximum(epochs)
    ts_min = collect(range(0.0, 90.0; length=NT))
    gmsts = Float64[SatelliteToolbox.jd_to_gmst(jd_ref + t / 1440.0) for t in ts_min]

    pos = sgp4_series_ecef(params, epochs, ts_min, gmsts; jd_ref=jd_ref)
    ds = sort(Float64[norm(pos[i, 1, :] .- pos[j, 1, :]) for i in 1:N for j in (i+1):N])
    dmed = ds[length(ds) ÷ 2]
    od = default_od_pairs(N; count=5)
    kw = (d_thresh=1.2 * dmed, τ=800.0, τsp=80.0, bellman_K=N, penalty_km=5.0e5)

    function loss_from_params(p)
        T = eltype(p)
        P = sgp4_series_ecef(p, epochs, ts_min, T.(gmsts); jd_ref=jd_ref)
        return network_kpi_loss(P; kind=:latency, od_pairs=od, kw...)
    end
    loss_ref = loss_from_params(params)
    grad_ref = ForwardDiff.gradient(loss_from_params, params)
    @test all(isfinite, grad_ref) && norm(grad_ref) > 0

    loss_bd, grad_bd = sgp4_network_kpi_gradient(params, epochs, ts_min; jd_ref=jd_ref,
                        gmsts=gmsts, engine=:blockdiag, kind=:latency, od_pairs=od, kw...)
    loss_en, grad_en = sgp4_network_kpi_gradient(params, epochs, ts_min; jd_ref=jd_ref,
                        gmsts=gmsts, engine=:enzyme, kind=:latency, od_pairs=od, kw...)

    @test loss_bd ≈ loss_ref rtol=1e-10
    @test loss_en ≈ loss_ref rtol=1e-10
    @test norm(grad_bd - grad_ref) / norm(grad_ref) < 1e-6
    @test norm(grad_en - grad_ref) / norm(grad_ref) < 1e-6

    # random directional derivative cross-check (central FD of the chain)
    Random.seed!(43)
    v = randn(length(params)); v ./= norm(v)
    dir = v .* max.(abs.(params), 1e-2)
    hs = 1e-6
    dd_fd = (loss_from_params(params .+ hs .* dir) - loss_from_params(params .- hs .* dir)) / (2hs)
    @test abs(dot(grad_bd, dir) - dd_fd) / (abs(dd_fd) + 1e-12) < 1e-5
end

# ── Step-3 acceptance: 7-class representative FD + attribution grouping ───────
@testset "7-class FD coverage and attribution grouping (latency)" begin
    N, NT = 4, 3
    params, epochs = nk_read_params_epochs(N)
    jd_ref = maximum(epochs)
    ts_min = collect(range(0.0, 45.0; length=NT))
    gmsts = Float64[SatelliteToolbox.jd_to_gmst(jd_ref + t / 1440.0) for t in ts_min]
    pos = sgp4_series_ecef(params, epochs, ts_min, gmsts; jd_ref=jd_ref)
    ds = sort(Float64[norm(pos[i, 1, :] .- pos[j, 1, :]) for i in 1:N for j in (i+1):N])
    od = default_od_pairs(N; count=3)
    kw = (d_thresh=1.3 * ds[length(ds) ÷ 2], τ=700.0, τsp=90.0, bellman_K=N, penalty_km=5.0e5)

    function loss_from_params(p)
        T = eltype(p)
        P = sgp4_series_ecef(p, epochs, ts_min, T.(gmsts); jd_ref=jd_ref)
        return network_kpi_loss(P; kind=:latency, od_pairs=od, kw...)
    end

    loss_ref = loss_from_params(params)
    grad_ref = ForwardDiff.gradient(loss_from_params, params)
    loss_bd, grad_bd = sgp4_network_kpi_gradient(params, epochs, ts_min; jd_ref=jd_ref,
                        gmsts=gmsts, engine=:blockdiag, kind=:latency, od_pairs=od, kw...)
    loss_en, grad_en = sgp4_network_kpi_gradient(params, epochs, ts_min; jd_ref=jd_ref,
                        gmsts=gmsts, engine=:enzyme, kind=:latency, od_pairs=od, kw...)

    @test loss_bd ≈ loss_ref rtol=1e-10
    @test loss_en ≈ loss_ref rtol=1e-10
    @test norm(grad_bd - grad_ref) / (norm(grad_ref) + 1e-12) < 1e-6
    @test norm(grad_en - grad_ref) / (norm(grad_ref) + 1e-12) < 1e-6
    @test norm(grad_bd - grad_en) / (norm(grad_ref) + 1e-12) < 1e-7

    # Minimal attribution grouping: partition 7N params into 7 orbital classes.
    class_groups = nk_param_class_groups(N)
    flat_groups = vcat(class_groups...)
    @test sort(flat_groups) == collect(1:length(params))
    @test length(unique(flat_groups)) == length(params)
    class_scores = [norm(params[idxs] .* grad_bd[idxs]) for idxs in class_groups]
    @test all(isfinite, class_scores)
    @test maximum(class_scores) > 0

    # Representative finite-difference checks for each class.
    class_names = ("n0", "e", "i", "RAAN", "argp", "M", "B*")
    rep_sat = 2
    gscale = maximum(abs, grad_ref)
    bstar_scale = maximum(abs, params[7:7:end])
    for c in 1:7
        idx = 7 * (rep_sat - 1) + c
        class_name = class_names[c]
        is_bstar = c == 7
        h0 = is_bstar ?
            1e-4 * max(abs(params[idx]), max(bstar_scale, 1e-5)) :
            1e-6 * max(abs(params[idx]), 1e-2)
        denom_floor = is_bstar ? (1e-8 * gscale + 1e-12) : (1e-10 * gscale)
        best_bd = Inf
        best_en = Inf
        @testset "class=$class_name representative FD" begin
            for sc in (0.1, 1.0, 10.0)
                h = sc * h0
                xp = copy(params); xm = copy(params); xp[idx] += h; xm[idx] -= h
                g_fd = (loss_from_params(xp) - loss_from_params(xm)) / (2h)
                rel_bd = abs(grad_bd[idx] - g_fd) / (abs(g_fd) + denom_floor)
                rel_en = abs(grad_en[idx] - g_fd) / (abs(g_fd) + denom_floor)
                best_bd = min(best_bd, rel_bd)
                best_en = min(best_en, rel_en)
            end
            thresh = is_bstar ? 5e-3 : 1e-3
            @test best_bd < thresh
            @test best_en < thresh
        end
    end
end

# ── connectivity: blockdiag vs enzyme whole-chain consistency ─────────────────
@testset "end-to-end connectivity engine consistency" begin
    N, NT = 6, 2
    params, epochs = nk_read_params_epochs(N)
    jd_ref = maximum(epochs)
    ts_min = [0.0, 30.0]
    gmsts = Float64[SatelliteToolbox.jd_to_gmst(jd_ref + t / 1440.0) for t in ts_min]
    pos = sgp4_series_ecef(params, epochs, ts_min, gmsts; jd_ref=jd_ref)
    ds = sort(Float64[norm(pos[i, 1, :] .- pos[j, 1, :]) for i in 1:N for j in (i+1):N])
    kw = (d_thresh=1.4 * ds[length(ds) ÷ 2], τ=700.0, fiedler_K=900)

    loss_bd, grad_bd = sgp4_network_kpi_gradient(params, epochs, ts_min; jd_ref=jd_ref,
                        gmsts=gmsts, engine=:blockdiag, kind=:connectivity, kw...)
    loss_en, grad_en = sgp4_network_kpi_gradient(params, epochs, ts_min; jd_ref=jd_ref,
                        gmsts=gmsts, engine=:enzyme, kind=:connectivity, kw...)

    @test length(grad_bd) == length(params)
    @test length(grad_en) == length(params)
    @test all(isfinite, grad_bd) && all(isfinite, grad_en)
    @test loss_bd ≈ loss_en rtol=1e-8
    @test norm(grad_bd - grad_en) / (norm(grad_en) + 1e-12) < 2e-4
end

# ── end-to-end connectivity: blockdiag(perturbation) vs central-FD-of-chain ───
@testset "end-to-end connectivity gradient (blockdiag) vs finite differences" begin
    N, NT = 10, 3
    params, epochs = nk_read_params_epochs(N)
    jd_ref = maximum(epochs)
    ts_min = collect(range(0.0, 60.0; length=NT))
    gmsts = Float64[SatelliteToolbox.jd_to_gmst(jd_ref + t / 1440.0) for t in ts_min]
    pos = sgp4_series_ecef(params, epochs, ts_min, gmsts; jd_ref=jd_ref)
    ds = sort(Float64[norm(pos[i, 1, :] .- pos[j, 1, :]) for i in 1:N for j in (i+1):N])
    kw = (d_thresh=1.6 * ds[length(ds) ÷ 2], τ=800.0, fiedler_K=600)

    loss_c, grad_c = sgp4_network_kpi_gradient(params, epochs, ts_min; jd_ref=jd_ref,
                        gmsts=gmsts, engine=:blockdiag, kind=:connectivity, kw...)
    @test all(isfinite, grad_c)

    function conn_loss(p)
        T = eltype(p)
        P = sgp4_series_ecef(p, epochs, ts_min, T.(gmsts); jd_ref=jd_ref)
        return network_kpi_loss(P; kind=:connectivity, kw...)
    end
    g_fd = similar(params)
    for i in eachindex(params)
        h = 1e-6 * max(abs(params[i]), 1e-2)
        xp = copy(params); xm = copy(params); xp[i] += h; xm[i] -= h
        g_fd[i] = (conn_loss(xp) - conn_loss(xm)) / (2h)
    end
    @test norm(grad_c - g_fd) / norm(g_fd) < 1e-3
end

# ── soft ↔ hard reference checks ──────────────────────────────────────────────
@testset "soft latency → Dijkstra, reachability → reachable fraction" begin
    N, NT = 14, 1
    P = nk_synth_positions(N, NT)
    Pt = P[:, 1, :]
    dth = 11000.0
    od = default_od_pairs(N; count=6)

    # hard references on a fully-connected (at this d_thresh) graph
    Ah = hard_isl_adjacency(Pt; d_thresh=dth)
    lat_hard, n_unreach = dijkstra_latency(Ah; od_pairs=[(s, d) for (s, d) in od])
    @test n_unreach == 0                       # graph connected for all od
    mean_hard_ms = sum(lat_hard) / length(lat_hard)

    # soft latency → hard as (τ, τsp) shrink
    prev = Inf
    for (τ, τsp) in ((300.0, 200.0), (80.0, 40.0), (15.0, 8.0))
        soft_ms = soft_expected_latency_ms(P; od_pairs=od, d_thresh=dth, τ=τ, τsp=τsp,
                                           bellman_K=N, penalty_km=5.0e5)
        gap = abs(soft_ms - mean_hard_ms) / mean_hard_ms
        prev = gap
    end
    @test prev < 0.05                          # tightest temps within 5% of Dijkstra

    # reachability: hard fraction = 1.0 here; soft → 1.0 with small τ
    r_soft = soft_reachability_ratio(P; od_pairs=od, d_thresh=dth, τ=15.0, τsp=8.0,
                                     bellman_K=N, reach_dmax_km=6.0e4, τ_reach=1.0e3)
    @test r_soft > 0.95
end

@testset "soft λ₂ tracks exact algebraic connectivity" begin
    Random.seed!(7)
    N, NT = 16, 1
    P = nk_synth_positions(N, NT); P .+= 20.0 .* randn(N, NT, 3)
    A = soft_isl_adjacency(P[:, 1, :]; d_thresh=9000.0, τ=300.0)
    d = vec(sum(A; dims=2)); L = Diagonal(d) - A
    λ2_exact = sort(eigvals(Symmetric(Matrix(L))))[2]
    λ2_soft = soft_algebraic_connectivity(P; d_thresh=9000.0, τ=300.0, fiedler_K=800)
    @test abs(λ2_soft - λ2_exact) / λ2_exact < 1e-3
end

# ── LOS: AD consistency (Enzyme == ForwardDiff), stiff so no central-FD claim ─
@testset "LOS KPI is finite and AD-consistent (Enzyme == ForwardDiff)" begin
    N, NT = 10, 1
    P = nk_synth_positions(N, NT; R=6921.0)
    od = default_od_pairs(N; count=4)
    cfg = network_kpi_config(N, NT; kind=:latency, od_pairs=od, d_thresh=13000.0,
                             τ=250.0, τsp=60.0, bellman_K=N, los=true, τ_los=120.0)
    loss_e, dP_e = network_kpi_loss_grad_positions(P, cfg)
    @test isfinite(loss_e) && all(isfinite, dP_e)
    g_fd = ForwardDiff.gradient(Q -> network_kpi_loss(Q; kind=:latency, od_pairs=od,
                                d_thresh=13000.0, τ=250.0, τsp=60.0, bellman_K=N,
                                los=true, τ_los=120.0), P)
    @test norm(dP_e - g_fd) / (norm(g_fd) + 1e-12) < 1e-8
end

# ── (3) boundary / domain errors ─────────────────────────────────────────────
@testset "domain and boundary errors" begin
    N, NT = 6, 2
    params, epochs = nk_read_params_epochs(N)
    jd_ref = maximum(epochs)
    ts_min = [0.0, 30.0]
    od = default_od_pairs(N; count=3)

    # SDP4 rejection propagates through the chain
    bad = copy(params); bad[1] = 2π / 226.0
    @test_throws ArgumentError sgp4_network_kpi_gradient(bad, epochs, ts_min;
        jd_ref=jd_ref, engine=:blockdiag, kind=:latency, od_pairs=od)

    # unknown engine / kind
    @test_throws ArgumentError sgp4_network_kpi_gradient(params, epochs, ts_min;
        jd_ref=jd_ref, engine=:nope, kind=:latency, od_pairs=od)
    @test_throws ArgumentError network_kpi_config(N, NT; kind=:bogus)

    # shape mismatches in chain inputs
    @test_throws ArgumentError sgp4_network_kpi_gradient(params[1:end-1], epochs, ts_min;
        jd_ref=jd_ref, kind=:latency, od_pairs=od)
    @test_throws ArgumentError sgp4_network_kpi_gradient(params, epochs, ts_min;
        jd_ref=jd_ref, gmsts=[0.0], kind=:latency, od_pairs=od)

    # OD index out of range; empty OD for latency
    @test_throws ArgumentError network_kpi_config(N, NT; kind=:latency, od_pairs=[(1, N + 1)])
    @test_throws ArgumentError network_kpi_config(N, NT; kind=:latency, od_pairs=Tuple{Int,Int}[])

    # bad temperatures
    @test_throws ArgumentError network_kpi_config(N, NT; kind=:latency, τ=-1.0, od_pairs=od)
    @test_throws ArgumentError network_kpi_config(N, NT; kind=:latency, τsp=0.0, od_pairs=od)
    @test_throws ArgumentError network_kpi_config(N, 0; kind=:latency, od_pairs=od)
    @test_throws ArgumentError network_kpi_config(0, NT; kind=:connectivity)
    @test_throws ArgumentError network_kpi_config(N, NT; kind=:latency, od_pairs=od, τ_reach=0.0)
    @test_throws ArgumentError network_kpi_config(N, NT; kind=:latency, od_pairs=od, penalty_km=-1.0)

    # LOS connectivity VJP is unsupported (must use Enzyme)
    P = nk_synth_positions(N, NT)
    cfg_los = network_kpi_config(N, NT; kind=:connectivity, los=true)
    @test_throws ArgumentError soft_connectivity_loss_vjp(P, cfg_los)
end

end # outer testset

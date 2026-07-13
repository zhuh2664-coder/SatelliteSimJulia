# =============================================================================
# Differentiable network KPIs from an (N, NT, 3) ECEF position series
# =============================================================================
# This closes the last link of the differentiable chain
#
#     orbital elements θ  →  SGP4 series (N,NT,3) ECEF  →  network KPI
#
# extending the coverage chain (`sgp4_e2e.jl`) from "orbit → geometric
# coverage" to "orbit → soft network KPI". Every KPI is a smooth proxy of a
# discrete network quantity, built from the general soft adjacency in
# `soft_isl_general.jl` and written as type-generic explicit loops so it is
# transparent to ForwardDiff and Enzyme.
#
# KPIs (all aggregated over the NT time slices):
#
#  1. Soft ≤K-hop path free energy (reported as soft expected latency, ms) —
#       softmin over neighbours (no self-loop) on
#       W[i,j] = d_ij + penalty·(1 − ã_ij). Softmin_τ(x) = −τ·log Σ exp(−x/τ).
#       Zero-cost self-loops are excluded (including them makes softmin(d,d) =
#       d−τlog2 each step and distances drift to −∞). `K` is part of the metric;
#       as τsp→0 and K ≥ diameter it recovers Dijkstra. Hard numerical reference:
#       `dijkstra_latency` on `hard_isl_adjacency`.
#
#  2. Soft soft-distance threshold ratio — mean of
#       σ((dmax − soft_dist)/τ_reach) ∈ [0,1]. Under a large dmax this tracks
#       the reachable-OD fraction; its hard limit is 1{dist < dmax}.
#
#  3. Soft algebraic connectivity λ₂ — Fiedler value of L = D − Ã via fixed-K
#       deflated power iteration. Exact numerical reference: 2nd-smallest
#       eigenvalue of the *same soft* Laplacian. Tape-free VJP uses
#       ∂λ₂/∂w_ij=(v_i−v_j)² and is accepted only when ‖(L−λ̂I)v‖ is below
#       tolerance; otherwise use Enzyme on the finite-K estimate.
#
# Honesty guardrails: these are SOFT proxies of discrete quantities; gradients
# through the hard {reachable / link on-off / argmin path} boundaries are only
# meaningful via the relaxation (Suh et al., ICML 2022). Temperatures trade
# proxy fidelity against smoothness. Reported hard/soft gaps quantify this.
# =============================================================================

import Enzyme
import ForwardDiff

export NetworkKPIConfig, network_kpi_config, default_od_pairs,
       soft_expected_latency_ms, soft_reachability_ratio, soft_algebraic_connectivity,
       network_kpi_loss, network_kpi_loss_grad_positions,
       soft_connectivity_loss_vjp, sgp4_network_kpi_gradient

# ── Configuration (immutable, Enzyme-Const friendly) ─────────────────────────

"""
    NetworkKPIConfig

Frozen configuration for the differentiable network KPIs. Build it with
[`network_kpi_config`](@ref) rather than the raw constructor. OD pairs are
stored in CSR-like flat form (`usrc`, `group_off`, `group_dst`) so that the
Enzyme-differentiated loss touches only flat `Int`/`Float64` fields.
"""
struct NetworkKPIConfig
    N::Int
    NT::Int
    # soft adjacency / edge weights
    d_thresh::Float64
    τ::Float64
    penalty_km::Float64
    los::Bool
    r_occ::Float64
    τ_los::Float64
    # soft Bellman-Ford
    τsp::Float64
    bellman_K::Int
    big::Float64
    speed_kms::Float64
    # reachability
    reach_dmax_km::Float64
    τ_reach::Float64
    # OD pairs (CSR by unique source)
    n_od::Int
    usrc::Vector{Int}
    group_off::Vector{Int}
    group_dst::Vector{Int}
    # Fiedler λ₂ (spectral shift c = 2·max_degree+1 is computed per slice)
    fiedler_x0::Vector{Float64}
    fiedler_K::Int
    # combination weights (loss = w_lat·lat − w_reach·reach − w_conn·λ₂)
    w_lat::Float64
    w_reach::Float64
    w_conn::Float64
end

"""
    default_od_pairs(N; count=min(N, 32), span=N ÷ 2) -> Vector{Tuple{Int,Int}}

Deterministic OD pair set: `count` sources evenly spaced over `1:N`, each paired
with the satellite `span` indices ahead (wrapping). Useful default when the
caller does not supply application OD pairs.
"""
function default_od_pairs(N::Int; count::Int = min(N, 32), span::Int = max(1, N ÷ 2))
    N >= 1 || throw(ArgumentError("default_od_pairs: N must be ≥ 1 (got $N)"))
    count = clamp(count, 1, N)
    srcs = unique(round.(Int, range(1, N; length = count)))
    return [(s, mod1(s + span, N)) for s in srcs if mod1(s + span, N) != s]
end

"""
    network_kpi_config(N, NT; kind=:latency, od_pairs=default_od_pairs(N), ...)
        -> NetworkKPIConfig

Build a [`NetworkKPIConfig`](@ref). `kind` is a convenience that sets the
combination weights when they are not given explicitly:
`:latency` → (1,0,0), `:reachability` → (0,1,0), `:connectivity` → (0,0,1),
`:combined` → (`w_lat`,`w_reach`,`w_conn`). All temperatures and thresholds are
keyword arguments with LEO-plausible defaults.
"""
function network_kpi_config(
    N::Int, NT::Int;
    kind::Symbol = :latency,
    od_pairs::AbstractVector{<:Tuple{Integer,Integer}} = default_od_pairs(N),
    d_thresh::Real = 5500.0,
    τ::Real = 200.0,
    penalty_km::Real = 5.0e5,
    los::Bool = false,
    r_occ::Real = ISL_R_OCCLUSION_KM,
    τ_los::Real = 50.0,
    τsp::Real = 40.0,
    bellman_K::Integer = 0,
    big::Real = 1.0e7,
    speed_kms::Real = SPEED_OF_LIGHT_KMS,
    reach_dmax_km::Real = 6.0e4,
    τ_reach::Real = 5.0e3,
    fiedler_K::Integer = 200,
    w_lat::Real = 0.0,
    w_reach::Real = 0.0,
    w_conn::Real = 0.0,
)
    N >= 1 || throw(ArgumentError("N must be ≥ 1"))
    NT >= 1 || throw(ArgumentError("NT must be ≥ 1"))
    d_thresh > 0 || throw(ArgumentError("d_thresh must be positive"))
    τ > 0 || throw(ArgumentError("τ must be positive"))
    τsp > 0 || throw(ArgumentError("τsp must be positive"))
    τ_reach > 0 || throw(ArgumentError("τ_reach must be positive"))
    penalty_km >= 0 || throw(ArgumentError("penalty_km must be non-negative"))
    fiedler_K >= 1 || throw(ArgumentError("fiedler_K must be ≥ 1"))
    r_occ > 0 || throw(ArgumentError("r_occ must be positive"))
    τ_los > 0 || throw(ArgumentError("τ_los must be positive"))
    speed_kms > 0 || throw(ArgumentError("speed_kms must be positive"))
    big > 0 || throw(ArgumentError("big (unreachable soft-distance sentinel) must be positive"))
    bellman_K == 0 || bellman_K >= 1 ||
        throw(ArgumentError("bellman_K must be ≥ 1 (or 0 for the N-dependent default)"))
    kind in (:latency, :reachability, :connectivity, :combined) ||
        throw(ArgumentError("unknown kind $kind (use :latency, :reachability, :connectivity, :combined)"))

    # resolve combination weights from `kind` unless explicitly overridden
    if w_lat == 0 && w_reach == 0 && w_conn == 0
        if kind === :latency
            w_lat = 1.0
        elseif kind === :reachability
            w_reach = 1.0
        elseif kind === :connectivity
            w_conn = 1.0
        elseif kind === :combined
            w_lat = 1.0; w_reach = 1.0; w_conn = 1.0
        else
            throw(ArgumentError("unknown kind $kind (use :latency, :reachability, :connectivity, :combined)"))
        end
    end

    # λ₂ (algebraic connectivity) needs at least 2 nodes: the deflation
    # subspace ⊥1 is empty for N=1, so the power iteration divides 0/0 and
    # silently returns NaN instead of erroring — reject explicitly instead.
    w_conn == 0 || N >= 2 ||
        throw(ArgumentError("algebraic connectivity (w_conn≠0) requires N ≥ 2 (got N=$N); λ₂ is undefined for a singleton network"))

    # validate + group OD pairs by source (CSR)
    for (s, d) in od_pairs
        (1 <= s <= N && 1 <= d <= N) ||
            throw(ArgumentError("OD pair ($s,$d) out of range 1:$N"))
    end
    n_od = length(od_pairs)
    (w_lat == 0 && w_reach == 0) || n_od >= 1 ||
        throw(ArgumentError("latency/reachability KPIs need at least one OD pair"))
    usrc = sort!(unique(first.(od_pairs)))
    group_off = Vector{Int}(undef, length(usrc) + 1)
    group_dst = Int[]
    group_off[1] = 1
    for (k, s) in enumerate(usrc)
        for (ss, dd) in od_pairs
            ss == s && push!(group_dst, dd)
        end
        group_off[k+1] = length(group_dst) + 1
    end

    bK = bellman_K == 0 ? max(4, min(N, 32)) : Int(bellman_K)

    # deterministic Fiedler init, orthogonal to 1, unit norm
    x0 = Float64[sin(1.3 * i) + 0.2 * cos(0.7 * i) for i in 1:N]
    m = sum(x0) / N
    @inbounds for i in 1:N; x0[i] -= m; end
    nrm = sqrt(sum(abs2, x0))
    nrm > 0 && (x0 ./= nrm)

    return NetworkKPIConfig(
        N, NT,
        Float64(d_thresh), Float64(τ), Float64(penalty_km), los,
        Float64(r_occ), Float64(τ_los),
        Float64(τsp), bK, Float64(big), Float64(speed_kms),
        Float64(reach_dmax_km), Float64(τ_reach),
        n_od, usrc, group_off, group_dst,
        x0, Int(fiedler_K),
        Float64(w_lat), Float64(w_reach), Float64(w_conn),
    )
end

# ── Per-slice kernels (type-generic, AD transparent) ─────────────────────────

# Soft edge weights W (N×N) at time slice t, read directly from the 3D series.
function _build_W(P::AbstractArray{T,3}, t::Int, cfg::NetworkKPIConfig) where {T<:Number}
    N = cfg.N
    W = zeros(T, N, N)
    dth = T(cfg.d_thresh); iτ = one(T) / T(cfg.τ); pen = T(cfg.penalty_km)
    ro = T(cfg.r_occ); τl = T(cfg.τ_los)
    @inbounds for i in 1:N
        for j in 1:N
            i == j && continue
            dx = P[i,t,1]-P[j,t,1]; dy = P[i,t,2]-P[j,t,2]; dz = P[i,t,3]-P[j,t,3]
            d = sqrt(dx*dx + dy*dy + dz*dz)
            a = _sigmoid((dth - d) * iτ)
            if cfg.los
                a *= soft_los_factor(P[i,t,1], P[i,t,2], P[i,t,3],
                                     P[j,t,1], P[j,t,2], P[j,t,3];
                                     r_occ=ro, τ_los=τl)
            end
            W[i, j] = d + pen * (one(T) - a)
        end
    end
    return W
end

# Soft adjacency A (N×N) at time slice t.
function _build_A(P::AbstractArray{T,3}, t::Int, cfg::NetworkKPIConfig) where {T<:Number}
    N = cfg.N
    A = zeros(T, N, N)
    dth = T(cfg.d_thresh); iτ = one(T) / T(cfg.τ); ro = T(cfg.r_occ); τl = T(cfg.τ_los)
    @inbounds for i in 1:N
        for j in (i+1):N
            dx = P[i,t,1]-P[j,t,1]; dy = P[i,t,2]-P[j,t,2]; dz = P[i,t,3]-P[j,t,3]
            d = sqrt(dx*dx + dy*dy + dz*dz)
            a = _sigmoid((dth - d) * iτ)
            if cfg.los
                a *= soft_los_factor(P[i,t,1], P[i,t,2], P[i,t,3],
                                     P[j,t,1], P[j,t,2], P[j,t,3];
                                     r_occ=ro, τ_los=τl)
            end
            A[i, j] = a; A[j, i] = a
        end
    end
    return A
end

# Soft ≤K-hop path free energy from source `s` (NOT classical Bellman-Ford).
#
# Each step softmins over *incoming neighbours only* (l ≠ j). Including the
# zero-cost self term W[j,j]=0 would make softmin(d,d)=d−τlog2 < d each
# iteration, so distances drift to −∞ (spectral radius of the soft transition
# > 1). With positive off-diagonal edge costs the K-hop free energy stays
# finite; as τsp→0 and K ≥ diameter it recovers Dijkstra on the support of
# soft-adjacent edges. `K` is therefore part of the metric definition.
function _soft_bellman(W::AbstractMatrix{T}, s::Int, K::Int, τsp::T, big::T) where {T<:Number}
    N = size(W, 1)
    dist = fill(big, N); dist[s] = zero(T)
    iτ = one(T) / τsp
    @inbounds for _ in 1:K
        nd = fill(big, N)
        nd[s] = zero(T)                         # reinstate source each hop
        for j in 1:N
            j == s && continue
            mn = T(Inf)
            for l in 1:N
                l == j && continue               # no zero-cost self-loop
                v = dist[l] + W[l, j]
                mn = ifelse(v < mn, v, mn)
            end
            # unreachable from any neighbour this hop → stay at `big`
            isfinite(mn) || continue
            acc = zero(T)
            for l in 1:N
                l == j && continue
                acc += exp(-(dist[l] + W[l, j] - mn) * iτ)
            end
            nd[j] = mn - τsp * log(acc)
        end
        dist = nd
    end
    return dist
end

# Deflated power iteration for the Fiedler pair (v ⊥ 1 unit, λ₂ Rayleigh quotient).
# The spectral shift `c` must satisfy c > λ_max(L) so that c − λ₂ is the largest
# eigenvalue of (cI − L) on 1^⊥, but must be as TIGHT as possible: a loose c
# (e.g. 2N) collapses the convergence ratio (c−λ₃)/(c−λ₂) → 1 and the iteration
# stalls. We use the Gershgorin bound c = 2·max_degree + 1 ≥ λ_max(L), computed
# from A. At true convergence the Rayleigh quotient is independent of c.
#
# Returns (v, λ̂₂, residual) with residual = ‖(L − λ̂₂ I)v‖₂. The perturbation
# VJP ∂λ₂/∂w_ij=(v_i−v_j)² is the gradient of the *true* eigenvalue only when
# this residual is negligible; otherwise differentiate the finite-K estimate
# (Enzyme) rather than the envelope identity.
function _fiedler_solve(A::AbstractMatrix{T}, x0::AbstractVector, K::Int) where {T<:Number}
    N = size(A, 1)
    D = Vector{T}(undef, N)
    dmax = zero(T)
    @inbounds for i in 1:N
        s = zero(T); for j in 1:N; s += A[i, j]; end
        D[i] = s
        dmax = ifelse(s > dmax, s, dmax)
    end
    c = T(2) * dmax + one(T)
    x = Vector{T}(undef, N)
    @inbounds for i in 1:N; x[i] = T(x0[i]); end
    @inbounds for _ in 1:K
        Ax = A * x
        y = Vector{T}(undef, N)
        for i in 1:N; y[i] = c * x[i] - D[i] * x[i] + Ax[i]; end   # (cI − L) x
        m = zero(T); for i in 1:N; m += y[i]; end; m /= N
        for i in 1:N; y[i] -= m; end                               # project ⊥ 1
        nrm2 = zero(T); for i in 1:N; nrm2 += y[i] * y[i]; end
        nrm2 > zero(T) || throw(ArgumentError("Fiedler power iteration collapsed (‖y‖=0); graph may be disconnected or init ⊥ Fiedler mode"))
        nrm = sqrt(nrm2)
        for i in 1:N; x[i] = y[i] / nrm; end
    end
    Ax = A * x
    num = zero(T); den = zero(T)
    @inbounds for i in 1:N
        num += x[i] * (D[i] * x[i] - Ax[i])   # xᵀ L x
        den += x[i] * x[i]
    end
    den > zero(T) || throw(ArgumentError("Fiedler Rayleigh denominator is zero"))
    λ2 = num / den
    # residual ‖(L − λ₂ I) v‖₂
    res2 = zero(T)
    @inbounds for i in 1:N
        ri = D[i] * x[i] - Ax[i] - λ2 * x[i]
        res2 += ri * ri
    end
    return x, λ2, sqrt(res2)
end

_fiedler_lambda2(A, x0, K) = _fiedler_solve(A, x0, K)[2]

# Relative residual tolerance for accepting the Hellmann–Feynman / envelope VJP.
const _FIEDLER_RESIDUAL_TOL = 1e-6

# ── KPI aggregations over time (type-generic) ────────────────────────────────

# Returns (mean latency ms, mean reachability ratio) over OD pairs and time.
function _latency_and_reach(P::AbstractArray{T,3}, cfg::NetworkKPIConfig) where {T<:Number}
    lat = zero(T); reach = zero(T)
    τsp = T(cfg.τsp); big = T(cfg.big)
    inv_c_ms = T(1000) / T(cfg.speed_kms)
    dmax = T(cfg.reach_dmax_km); iτr = one(T) / T(cfg.τ_reach)
    @inbounds for t in 1:cfg.NT
        W = _build_W(P, t, cfg)
        for k in 1:length(cfg.usrc)
            s = cfg.usrc[k]
            dist = _soft_bellman(W, s, cfg.bellman_K, τsp, big)
            for m in cfg.group_off[k]:(cfg.group_off[k+1]-1)
                d = cfg.group_dst[m]
                lat += dist[d] * inv_c_ms
                reach += _sigmoid((dmax - dist[d]) * iτr)
            end
        end
    end
    n = T(cfg.n_od * cfg.NT)
    return lat / n, reach / n
end

# Mean algebraic connectivity λ₂ over time.
function _connectivity(P::AbstractArray{T,3}, cfg::NetworkKPIConfig) where {T<:Number}
    conn = zero(T)
    @inbounds for t in 1:cfg.NT
        A = _build_A(P, t, cfg)
        conn += _fiedler_lambda2(A, cfg.fiedler_x0, cfg.fiedler_K)
    end
    return conn / T(cfg.NT)
end

# Combined training loss (lower is better).
function _network_kpi_loss(P::AbstractArray{T,3}, cfg::NetworkKPIConfig) where {T<:Number}
    L = zero(T)
    if cfg.w_lat != 0 || cfg.w_reach != 0
        lat, reach = _latency_and_reach(P, cfg)
        L += T(cfg.w_lat) * lat - T(cfg.w_reach) * reach
    end
    if cfg.w_conn != 0
        L += -T(cfg.w_conn) * _connectivity(P, cfg)
    end
    return L
end

# ── Public scalar KPIs (interpretable, natural sign) ─────────────────────────

"""
    soft_expected_latency_ms(P; od_pairs=default_od_pairs(size(P,1)), kwargs...) -> ms

Mean soft expected end-to-end latency (milliseconds) over the OD pairs and the
`NT` time slices of the `(N,NT,3)` ECEF series `P`. Differentiable in `P`.
Hard reference: `dijkstra_latency(hard_isl_adjacency(...))`.
"""
function soft_expected_latency_ms(P::AbstractArray{T,3}; od_pairs = default_od_pairs(size(P,1)), kwargs...) where {T<:Number}
    cfg = network_kpi_config(size(P,1), size(P,2); kind=:latency, od_pairs=od_pairs, kwargs...)
    return _latency_and_reach(P, cfg)[1]
end

"""
    soft_reachability_ratio(P; od_pairs=default_od_pairs(size(P,1)), kwargs...) -> [0,1]

Mean soft reachability ratio over OD pairs and time. Hard reference: fraction of
OD pairs with a finite Dijkstra distance.
"""
function soft_reachability_ratio(P::AbstractArray{T,3}; od_pairs = default_od_pairs(size(P,1)), kwargs...) where {T<:Number}
    cfg = network_kpi_config(size(P,1), size(P,2); kind=:reachability, od_pairs=od_pairs, kwargs...)
    return _latency_and_reach(P, cfg)[2]
end

"""
    soft_algebraic_connectivity(P; kwargs...) -> λ₂

Mean soft algebraic connectivity (Fiedler value of L = D − Ã) over time, via
fixed-K deflated power iteration. Hard reference: exact 2nd-smallest eigenvalue
of L. Convergence needs a spectral gap and enough `fiedler_K` iterations.
"""
function soft_algebraic_connectivity(P::AbstractArray{T,3}; kwargs...) where {T<:Number}
    cfg = network_kpi_config(size(P,1), size(P,2); kind=:connectivity, kwargs...)
    return _connectivity(P, cfg)
end

"""
    network_kpi_loss(P; kind=:latency, od_pairs=default_od_pairs(size(P,1)), kwargs...) -> scalar

Combined differentiable network-KPI training loss (lower is better):
`w_lat·latency_ms − w_reach·reachability − w_conn·λ₂`. Weights follow `kind`
unless given explicitly. See [`network_kpi_config`](@ref).
"""
function network_kpi_loss(P::AbstractArray{T,3}; kind::Symbol = :latency,
                          od_pairs = default_od_pairs(size(P,1)), kwargs...) where {T<:Number}
    cfg = network_kpi_config(size(P,1), size(P,2); kind=kind, od_pairs=od_pairs, kwargs...)
    return _network_kpi_loss(P, cfg)
end

# ── dL/dP adjoints ───────────────────────────────────────────────────────────

"""
    network_kpi_loss_grad_positions(P, cfg) -> (loss, dP)

`dL/dP` via one Enzyme reverse pass over the pure-Julia loss. Works for any
`kind`; memory scales with the reverse tape (`O(K·N²·|src|·NT)`), so it is the
right choice at small/moderate `N`. For large-`N` connectivity use
[`soft_connectivity_loss_vjp`](@ref) (tape-free).

Accepts any `AbstractArray{Float64,3}`. `Enzyme.make_zero` recursively preserves
the primal's concrete array/view structure, so a `SubArray` is differentiated
without copying the primal into a plain `Array`.
"""
function network_kpi_loss_grad_positions(P::AbstractArray{Float64,3}, cfg::NetworkKPIConfig)
    size(P) == (cfg.N, cfg.NT, 3) ||
        throw(ArgumentError("network_kpi_loss_grad_positions: positions size $(size(P)) ≠ (N=$(cfg.N), NT=$(cfg.NT), 3) from cfg"))
    dP = Enzyme.make_zero(P)
    res = Enzyme.autodiff(
        Enzyme.set_runtime_activity(Enzyme.ReverseWithPrimal),
        Enzyme.Const(_network_kpi_loss),
        Enzyme.Active,
        Enzyme.Duplicated(P, dP),
        Enzyme.Const(cfg),
    )
    return res[2], dP
end

"""
    soft_connectivity_loss_vjp(P, cfg) -> (loss, dP)

Tape-free adjoint of the connectivity loss `L = −w_conn·mean_t λ₂(Ã_t)` using
the undirected edge-weight perturbation identity `∂λ₂/∂w_ij = (v_i − v_j)²`
(Hellmann–Feynman / envelope; exact for a *converged* simple eigenpair), chained
analytically through the distance→sigmoid geometry. Requires `los == false`.

The identity is **not** the gradient of the finite-`K` Rayleigh estimate when
the residual `‖(L−λ̂I)v‖` is non-negligible. Each slice is therefore checked
against `_FIEDLER_RESIDUAL_TOL`; on failure this throws (caller should increase
`fiedler_K` or use `engine=:enzyme`, which differentiates the finite-K estimate
itself). Time is `O(K·N²·NT)`; tape-free memory is `O(N² + N·NT)`.
"""
function soft_connectivity_loss_vjp(P::AbstractArray{Float64,3}, cfg::NetworkKPIConfig)
    cfg.los && throw(ArgumentError("soft_connectivity_loss_vjp supports los=false only; use engine=:enzyme for LOS"))
    size(P) == (cfg.N, cfg.NT, 3) ||
        throw(ArgumentError("soft_connectivity_loss_vjp: positions size $(size(P)) ≠ (N=$(cfg.N), NT=$(cfg.NT), 3) from cfg"))
    N, NT = cfg.N, cfg.NT
    dP = zeros(Float64, N, NT, 3)
    dth = cfg.d_thresh; iτ = 1.0 / cfg.τ
    total_λ2 = 0.0
    coef = -cfg.w_conn / NT                     # dL/dλ2 per slice
    eps_d = 1e-12
    for t in 1:NT
        A = _build_A(P, t, cfg)
        v, λ2, resid = _fiedler_solve(A, cfg.fiedler_x0, cfg.fiedler_K)
        # Envelope VJP equals ∂(true λ₂) only at convergence; refuse otherwise.
        scale = max(abs(λ2), 1.0)
        resid / scale <= _FIEDLER_RESIDUAL_TOL ||
            throw(ArgumentError(string(
                "Fiedler residual ", resid, " / ", scale, " exceeds tol ",
                _FIEDLER_RESIDUAL_TOL, " at time slice ", t,
                "; increase fiedler_K or use engine=:enzyme (differentiates the finite-K estimate)")))
        total_λ2 += λ2
        @inbounds for i in 1:N
            xi = P[i,t,1]; yi = P[i,t,2]; zi = P[i,t,3]
            for j in (i+1):N
                dx = xi - P[j,t,1]; dy = yi - P[j,t,2]; dz = zi - P[j,t,3]
                d2 = dx*dx + dy*dy + dz*dz
                d = sqrt(d2 + eps_d)            # regularized; rejects 0/0 at coincidence
                a = _sigmoid((dth - d) / cfg.τ) # divide by τ, not multiply by 1/τ
                # dL/dw_ij = coef · (v_i − v_j)²  (undirected coupled weight)
                gA = coef * (v[i] - v[j])^2
                dA_dd = a * (1.0 - a) * (-1.0 / cfg.τ)
                s = gA * dA_dd / d
                gx = s * dx; gy = s * dy; gz = s * dz
                dP[i,t,1] += gx; dP[i,t,2] += gy; dP[i,t,3] += gz
                dP[j,t,1] -= gx; dP[j,t,2] -= gy; dP[j,t,3] -= gz
            end
        end
    end
    loss = -cfg.w_conn * (total_λ2 / NT)
    return loss, dP
end

# ── SGP4 → network KPI chaining ──────────────────────────────────────────────

# Block-diagonal contraction: grad_{θ_i} L = J_iᵀ · vec(dP[i,:,:]) with
# J_i = ∂vec(_satellite_series_ecef(θ_i))/∂θ_i (3NT×7). Mirrors the coverage
# block-diagonal engine in `sgp4_e2e.jl`; reuses its per-satellite kernel.
function _blockdiag_contract_params(
    params::Vector{Float64}, epochs, ts_min, jd_ref, gmsts,
    dP::AbstractArray{Float64,3},
)
    N = length(epochs)
    grad = similar(params)
    Threads.@threads for i in 1:N
        idx = 7 * (i - 1)
        p_i = params[idx+1:idx+7]
        epoch_i = epochs[i]
        sat_series = p -> _satellite_series_ecef(p, epoch_i, ts_min, jd_ref, gmsts)
        cfg = ForwardDiff.JacobianConfig(sat_series, p_i, ForwardDiff.Chunk{7}())
        J_i = ForwardDiff.jacobian(sat_series, p_i, cfg)   # (3NT) × 7
        g_i = J_i' * vec(dP[i, :, :])
        for j in 1:7
            grad[idx+j] = g_i[j]
        end
    end
    return grad
end

# Whole-chain Enzyme context and loss (cross-validation engine, small N).
struct _E2ENetworkContext
    n::Int
    nt::Int
    epochs::Vector{Float64}
    jd_ref::Float64
    ts_min::Vector{Float64}
    gmsts::Vector{Float64}
    cfg::NetworkKPIConfig
end

function _e2e_network_loss(p::AbstractVector{T}, ctx::_E2ENetworkContext) where {T<:Number}
    pos = Array{T}(undef, ctx.n, ctx.nt, 3)
    @inbounds for i in 1:ctx.n
        idx = 7 * (i - 1)
        epoch = ctx.epochs[i]
        sgp4d = SatelliteToolboxSgp4.sgp4_init(
            epoch, p[idx+1], p[idx+2], p[idx+3], p[idx+4], p[idx+5], p[idx+6], p[idx+7],
        )
        dt0 = (ctx.jd_ref - epoch) * 1440.0
        for k in 1:ctx.nt
            r, _ = SatelliteToolboxSgp4.sgp4!(sgp4d, T(dt0 + ctx.ts_min[k]))
            x, y, z = teme_to_ecef_simple([r[1], r[2], r[3]], T(ctx.gmsts[k]))
            pos[i, k, 1] = x; pos[i, k, 2] = y; pos[i, k, 3] = z
        end
    end
    return _network_kpi_loss(pos, ctx.cfg)
end

function _enzyme_network_gradient(params::Vector{Float64}, ctx::_E2ENetworkContext)
    dp = zeros(Float64, length(params))
    ret = Enzyme.autodiff(
        Enzyme.set_runtime_activity(Enzyme.ReverseWithPrimal),
        Enzyme.Const(_e2e_network_loss),
        Enzyme.Active,
        Enzyme.Duplicated(params, dp),
        Enzyme.Const(ctx),
    )
    return ret[2], dp
end

"""
    sgp4_network_kpi_gradient(params, epochs, ts_min;
        jd_ref, gmsts=nothing, engine=:blockdiag, kind=:latency,
        od_pairs=default_od_pairs(length(epochs)), kpi_kwargs...) -> (loss, grad)

Loss and gradient of a network KPI evaluated on the SGP4 ECEF series, w.r.t. the
flat `7N` TLE parameter vector. The chain is
`params → sgp4_series_ecef → network_kpi_loss`.

Engines:
- `:blockdiag` (default, scalable): `dL/dP` then per-satellite ForwardDiff SGP4
  Jacobians (`Threads.@threads`). For `kind==:connectivity` with `los=false`,
  `dL/dP` uses the tape-free perturbation VJP; otherwise it uses one Enzyme
  reverse pass over the loss.
- `:enzyme` (cross-validation, small N): one Enzyme reverse pass over the whole
  chain.

`kpi_kwargs` are forwarded to [`network_kpi_config`](@ref) (`d_thresh`, `τ`,
`τsp`, `bellman_K`, `fiedler_K`, `los`, weights, …). The time contract matches
`sgp4_series_ecef` (explicit `jd_ref`, GMST z-rotation, SDP4 rejected).
"""
function sgp4_network_kpi_gradient(
    params::Vector{Float64}, epochs, ts_min::AbstractVector;
    jd_ref, gmsts = nothing, engine::Symbol = :blockdiag,
    kind::Symbol = :latency,
    od_pairs = default_od_pairs(length(epochs)),
    kpi_kwargs...,
)
    _validate_sgp4_params(params)
    N = length(epochs)
    length(params) == 7N ||
        throw(ArgumentError("params length $(length(params)) ≠ 7 × $(N) epochs"))
    NT = length(ts_min)
    gmsts_v = gmsts === nothing ?
        Float64[SatelliteToolbox.jd_to_gmst(jd_ref + t / 1440.0) for t in ts_min] :
        collect(Float64, gmsts)
    length(gmsts_v) == NT ||
        throw(ArgumentError("gmsts length $(length(gmsts_v)) ≠ $(NT) time steps"))

    cfg = network_kpi_config(N, NT; kind=kind, od_pairs=od_pairs, kpi_kwargs...)

    if engine === :blockdiag
        positions = sgp4_series_ecef(params, epochs, ts_min, gmsts_v; jd_ref=jd_ref)
        if cfg.w_conn != 0 && cfg.w_lat == 0 && cfg.w_reach == 0 && !cfg.los
            # Prefer the tape-free envelope VJP when the Fiedler residual is
            # small; otherwise differentiate the finite-K Rayleigh estimate.
            loss, dP = try
                soft_connectivity_loss_vjp(positions, cfg)
            catch e
                e isa ArgumentError && occursin("Fiedler residual", e.msg) || rethrow()
                network_kpi_loss_grad_positions(positions, cfg)
            end
        else
            loss, dP = network_kpi_loss_grad_positions(positions, cfg)
        end
        grad = _blockdiag_contract_params(params, collect(Float64, epochs),
                                          collect(Float64, ts_min), Float64(jd_ref),
                                          gmsts_v, dP)
        return loss, grad
    elseif engine === :enzyme
        ctx = _E2ENetworkContext(N, NT, collect(Float64, epochs), Float64(jd_ref),
                                 collect(Float64, ts_min), gmsts_v, cfg)
        return _enzyme_network_gradient(params, ctx)
    else
        throw(ArgumentError("unknown engine $engine (use :blockdiag or :enzyme)"))
    end
end

# =============================================================================
# End-to-end differentiable SGP4 constellation gradient
# =============================================================================
# Real TLE parameters → time-series SGP4 (TEME) → GMST z-rotation → ECEF →
# coverage loss, differentiated in reverse mode with respect to all 7N orbital
# parameters.
#
# Engines (selected via `engine` kwarg of `sgp4_e2e_gradient`):
#   :enzyme    (default) — one Enzyme reverse pass over the whole chain.
#                Cost ≈ 8–9× one forward evaluation, independent of N·7.
#   :blockdiag — cross-validation path. One custom CPU adjoint through the
#                loss (`coverage_loss_vjp` → dL/dP), then a per-satellite
#                ForwardDiff Jacobian J_i = ∂vec(P[i,:,:])/∂θ_i (3NT×7,
#                chunk=7, Threads-parallel) contracted as ∇_{θ_i}L = J_iᵀ·v_i.
#                Exploits the block-diagonal structure of ∂P/∂θ.
#
# Time contract (explicit, no hidden reference):
#   - `jd_ref` is a REQUIRED argument: the common wall-clock reference (Julian
#     date, UTC). Each satellite is propagated with dt_i = (jd_ref − epoch_i)
#     × 1440 + ts_min[k] minutes, so all satellites are sampled at the same
#     absolute instants regardless of their individual TLE epochs.
#   - GMST is evaluated at jd_ref + ts_min/1440 with the UTC≈UT1 approximation
#     and applied as a plain z-rotation (TEME→PEF≈ECEF, no polar motion) — the
#     same convention as the CPU main chain's `r_eci_to_ecef(TEME, PEF)`
#     approximation. GMST is a constant with respect to the orbital
#     parameters and is never differentiated.
#
# Domain: near-Earth SGP4 only. TLEs with orbital period ≥ 225 min would
# require SDP4 (deep space) and are rejected with an ArgumentError.
# =============================================================================

import Enzyme
import ForwardDiff
import SatelliteToolbox
import SatelliteToolboxSgp4

export sgp4_constellation_series, sgp4_series_ecef,
       coverage_loss_vjp, sgp4_e2e_gradient

# SGP4 (near-Earth) is valid below this orbital period; longer periods need SDP4.
const SGP4_MAX_PERIOD_MIN = 225.0

# ── Parameter-domain validation (Float64 entry points only; AD duals skip) ────

function _validate_sgp4_params(params::AbstractVector)
    eltype(params) <: AbstractFloat || return nothing
    length(params) % 7 == 0 ||
        throw(ArgumentError("params length $(length(params)) is not a multiple of 7"))
    n_sats = length(params) ÷ 7
    for i in 1:n_sats
        idx = 7 * (i - 1)
        n0 = params[idx+1]
        e0 = params[idx+2]
        bstar = params[idx+7]
        isfinite(n0) && n0 > 0 ||
            throw(ArgumentError("satellite $i: mean motion n₀=$n0 rad/min must be finite and positive"))
        period_min = 2π / n0
        period_min < SGP4_MAX_PERIOD_MIN ||
            throw(ArgumentError(string(
                "satellite $i: orbital period $(round(period_min; digits=2)) min ≥ ",
                "$(SGP4_MAX_PERIOD_MIN) min requires SDP4 (deep space), which is not supported")))
        0 <= e0 < 1 ||
            throw(ArgumentError("satellite $i: eccentricity $e0 outside [0, 1)"))
        isfinite(bstar) && abs(bstar) < 1 ||
            throw(ArgumentError("satellite $i: B*=$bstar outside plausible range (|B*| < 1)"))
    end
    return nothing
end

# ── Per-satellite series helpers (AD transparent) ─────────────────────────────
# Both return an (NT, 3) matrix so that `vec(out)` has the same memory order as
# `vec(positions[i, :, :])` for the (N, NT, 3) constellation array. The
# block-diagonal contraction J_iᵀ · vec(dP[i,:,:]) relies on this layout.

function _satellite_series_teme(
    p::AbstractVector{T},
    epoch,
    ts_min::AbstractVector,
    jd_ref,
) where T <: Number
    NT = length(ts_min)
    sgp4d = SatelliteToolboxSgp4.sgp4_init(
        epoch, p[1], p[2], p[3], p[4], p[5], p[6], p[7],
    )
    dt0 = (jd_ref - epoch) * 1440.0
    out = Array{T}(undef, NT, 3)
    for k in 1:NT
        r, _ = SatelliteToolboxSgp4.sgp4!(sgp4d, T(dt0 + ts_min[k]))
        out[k, 1] = r[1]
        out[k, 2] = r[2]
        out[k, 3] = r[3]
    end
    return out
end

function _satellite_series_ecef(
    p::AbstractVector{T},
    epoch,
    ts_min::AbstractVector,
    jd_ref,
    gmsts,
) where T <: Number
    NT = length(ts_min)
    sgp4d = SatelliteToolboxSgp4.sgp4_init(
        epoch, p[1], p[2], p[3], p[4], p[5], p[6], p[7],
    )
    dt0 = (jd_ref - epoch) * 1440.0
    out = Array{T}(undef, NT, 3)
    for k in 1:NT
        r, _ = SatelliteToolboxSgp4.sgp4!(sgp4d, T(dt0 + ts_min[k]))
        x, y, z = teme_to_ecef_simple(r, T(gmsts[k]))
        out[k, 1] = x
        out[k, 2] = y
        out[k, 3] = z
    end
    return out
end

# ── Public forward API ───────────────────────────────────────────────────────

"""
    sgp4_constellation_series(params, epochs, ts_min; jd_ref) -> (N, NT, 3)

Propagate a constellation from flat TLE parameters to a time series of TEME
positions (km). `params` is a flat vector of length `7N` in SGP4 internal
units/order: `[n₀ (rad/min), e₀, i₀ (rad), Ω₀ (rad), ω₀ (rad), M₀ (rad), B*]`
per satellite. `epochs` are the per-satellite TLE epochs (Julian date).

`jd_ref` is REQUIRED: the common wall-clock reference (Julian date, UTC).
Propagation times are `dt_i = (jd_ref − epoch_i) × 1440 + ts_min` minutes, so
all satellites are sampled at the same absolute instants. Callers own this
choice; the kernel never silently derives it from the epoch subset.

AD transparent (works with ForwardDiff duals and under Enzyme).
"""
function sgp4_constellation_series(
    params::AbstractVector,
    epochs,
    ts_min::AbstractVector;
    jd_ref,
)
    _validate_sgp4_params(params)
    N = length(epochs)
    length(params) == 7N ||
        throw(ArgumentError("params length $(length(params)) ≠ 7 × $(N) epochs"))
    NT = length(ts_min)
    T = eltype(params)
    pos = Array{T}(undef, N, NT, 3)
    for i in 1:N
        idx = 7 * (i - 1)
        s = _satellite_series_teme(params[idx+1:idx+7], epochs[i], ts_min, jd_ref)
        for k in 1:NT
            pos[i, k, 1] = s[k, 1]
            pos[i, k, 2] = s[k, 2]
            pos[i, k, 3] = s[k, 3]
        end
    end
    return pos
end

"""
    sgp4_series_ecef(params, epochs, ts_min, gmsts; jd_ref) -> (N, NT, 3)

Same as `sgp4_constellation_series`, but rotates each TEME position into ECEF
with a plain GMST z-rotation (TEME→PEF≈ECEF, UTC≈UT1, no polar motion).
`gmsts` must contain one GMST value (rad) per time step, evaluated at
`jd_ref + ts_min/1440`; it is a constant with respect to the orbital
parameters and is never differentiated.
"""
function sgp4_series_ecef(
    params::AbstractVector,
    epochs,
    ts_min::AbstractVector,
    gmsts::AbstractVector;
    jd_ref,
)
    _validate_sgp4_params(params)
    N = length(epochs)
    length(params) == 7N ||
        throw(ArgumentError("params length $(length(params)) ≠ 7 × $(N) epochs"))
    NT = length(ts_min)
    length(gmsts) == NT ||
        throw(ArgumentError("gmsts length $(length(gmsts)) ≠ $(NT) time steps"))
    T = eltype(params)
    pos = Array{T}(undef, N, NT, 3)
    for i in 1:N
        idx = 7 * (i - 1)
        s = _satellite_series_ecef(params[idx+1:idx+7], epochs[i], ts_min, jd_ref, gmsts)
        for k in 1:NT
            pos[i, k, 1] = s[k, 1]
            pos[i, k, 2] = s[k, 2]
            pos[i, k, 3] = s[k, 3]
        end
    end
    return pos
end

# ── CPU adjoint for coverage_loss ────────────────────────────────────────────

"""
    _elevation_deg_grad(sx, sy, sz, gx, gy, gz)

Analytical gradient of `_elevation_deg` with respect to the satellite position
`(sx, sy, sz)`. Same math as `_elevation_deg_grad_gpu` in
`packages/SatelliteSimGPU/src/adjoint.jl`.
"""
function _elevation_deg_grad(
    sx::T, sy::T, sz::T, gx::T, gy::T, gz::T,
) where T <: Number
    dx, dy, dz = sx - gx, sy - gy, sz - gz
    gr = sqrt(gx^2 + gy^2 + gz^2)
    nx, ny, nz = gx / gr, gy / gr, gz / gr
    along = dx * nx + dy * ny + dz * nz
    tvx = dx - along * nx
    tvy = dy - along * ny
    tvz = dz - along * nz
    tang = sqrt(tvx^2 + tvy^2 + tvz^2 + T(1e-12))
    denom = along * along + tang * tang
    k = T(180.0 / π) / denom
    gxo = k * (tang * nx - along * tvx / tang)
    gyo = k * (tang * ny - along * tvy / tang)
    gzo = k * (tang * nz - along * tvz / tang)
    return (gxo, gyo, gzo)
end

"""
    coverage_loss_vjp(positions, ground_pts, weights; kwargs...) -> (loss, dP)

Custom CPU adjoint for `coverage_loss`. Returns the scalar loss and the
gradient `dP = ∂loss/∂positions` of size `(N, NT, 3)` in one forward + one
backward sweep. The backward math mirrors the GPU adjoint in
`packages/SatelliteSimGPU/src/adjoint.jl` and is validated against
ForwardDiff-on-positions in the test suite.

`dt` must be the real spacing of the time grid in minutes (revisit gaps are
accumulated as `gap = (gap + dt) × (1 − coverage)` per step).
"""
function coverage_loss_vjp(
    positions::AbstractArray{T,3},
    ground_pts::AbstractMatrix{T},
    weights::AbstractVector{T};
    min_el::T   = T(10.0),
    τ_cov::T    = T(5.0),
    dt::T       = T(1.0),
    τ_revisit::T = one(T),
    λ::T        = T(0.1),
) where T <: Number
    N, NT, _ = size(positions)
    G = size(ground_pts, 1)

    total_cov = zero(T)
    total_weight = zero(T)
    step_cov = Matrix{T}(undef, G, NT)
    gaps = Matrix{T}(undef, G, NT)
    revisit_gaps = Vector{T}(undef, G)

    for g in 1:G
        gx, gy, gz = ground_pts[g, 1], ground_pts[g, 2], ground_pts[g, 3]
        w = weights[g]
        gap = zero(T)
        for t in 1:NT
            p_none = one(T)
            for i in 1:N
                sx, sy, sz = positions[i, t, 1], positions[i, t, 2], positions[i, t, 3]
                el = _elevation_deg(sx, sy, sz, gx, gy, gz)
                c = soft_coverage(el, min_el; τ = τ_cov)
                p_none *= (one(T) - c)
            end
            cov_t = one(T) - p_none
            step_cov[g, t] = cov_t
            total_cov += cov_t * w
            total_weight += w
            gap = (gap + dt) * (one(T) - cov_t)
            gaps[g, t] = gap
        end
        revisit_gaps[g] = gap * w
    end

    mean_cov = total_cov / total_weight
    worst_revisit = logsumexp_max(revisit_gaps; τ = τ_revisit)
    loss = -mean_cov + λ * worst_revisit

    # Reverse pass
    dP = fill(zero(T), N, NT, 3)
    mean_coef = -one(T) / total_weight

    rg_max = maximum(revisit_gaps)
    ex = exp.((revisit_gaps .- rg_max) ./ τ_revisit)
    sm = ex ./ sum(ex)

    inv_τ_cov = one(T) / τ_cov

    for g in 1:G
        gx, gy, gz = ground_pts[g, 1], ground_pts[g, 2], ground_pts[g, 3]
        w = weights[g]

        # revisit_gaps[g] = gap_NT · w; LSE softmax gives ∂worst/∂revisit_gaps.
        d_gap = λ * sm[g] * w

        for t in NT:-1:1
            cov_t = step_cov[g, t]
            gap_prev = t == 1 ? zero(T) : gaps[g, t - 1]

            # dL/d(step_cov[g,t]): mean-coverage term + revisit recursion term
            # gap_t = (gap_{t-1} + dt)·(1 − step_cov_t).
            dsc = mean_coef * w + d_gap * (-(gap_prev + dt))

            for i in 1:N
                sx, sy, sz = positions[i, t, 1], positions[i, t, 2], positions[i, t, 3]
                el = _elevation_deg(sx, sy, sz, gx, gy, gz)
                c = soft_coverage(el, min_el; τ = τ_cov)
                egx, egy, egz = _elevation_deg_grad(sx, sy, sz, gx, gy, gz)

                # noisy-OR × sigmoid chain, algebraically combined to avoid the
                # 0/0 of (1−cov)/(1−c) when c saturates at one:
                # ∂cov/∂el_i = (1−cov_t)/(1−c_i) · c_i(1−c_i)/τ = (1−cov_t)·c_i/τ.
                coef = dsc * (one(T) - cov_t) * c * inv_τ_cov

                dP[i, t, 1] += coef * egx
                dP[i, t, 2] += coef * egy
                dP[i, t, 3] += coef * egz
            end

            d_gap = d_gap * (one(T) - cov_t)
        end
    end

    return loss, dP
end

# ── Enzyme whole-chain reverse (main engine) ──────────────────────────────────

# All non-differentiated constants live in this context so the Enzyme call can
# mark them Const explicitly.
struct _E2ELossContext
    n::Int
    nt::Int
    epochs::Vector{Float64}
    jd_ref::Float64
    ts_min::Vector{Float64}
    gmsts::Vector{Float64}
    ground_pts::Matrix{Float64}
    weights::Vector{Float64}
    min_el::Float64
    τ_cov::Float64
    dt::Float64
    τ_revisit::Float64
    λ::Float64
end

function _e2e_loss(p::AbstractVector{T}, ctx::_E2ELossContext) where T <: Number
    pos = Array{T}(undef, ctx.n, ctx.nt, 3)
    for i in 1:ctx.n
        idx = 7 * (i - 1)
        epoch = ctx.epochs[i]
        sgp4d = SatelliteToolboxSgp4.sgp4_init(
            epoch,
            p[idx+1], p[idx+2], p[idx+3], p[idx+4], p[idx+5], p[idx+6], p[idx+7],
        )
        dt0 = (ctx.jd_ref - epoch) * 1440.0
        for k in 1:ctx.nt
            r, _ = SatelliteToolboxSgp4.sgp4!(sgp4d, T(dt0 + ctx.ts_min[k]))
            x, y, z = teme_to_ecef_simple([r[1], r[2], r[3]], T(ctx.gmsts[k]))
            pos[i, k, 1] = x
            pos[i, k, 2] = y
            pos[i, k, 3] = z
        end
    end
    return coverage_loss(
        pos, T.(ctx.ground_pts), T.(ctx.weights);
        min_el = T(ctx.min_el), τ_cov = T(ctx.τ_cov), dt = T(ctx.dt),
        τ_revisit = T(ctx.τ_revisit), λ = T(ctx.λ),
    )
end

function _enzyme_gradient(params::Vector{Float64}, ctx::_E2ELossContext)
    dp = zeros(Float64, length(params))
    ret = Enzyme.autodiff(
        Enzyme.set_runtime_activity(Enzyme.ReverseWithPrimal),
        Enzyme.Const(_e2e_loss),
        Enzyme.Active,
        Enzyme.Duplicated(params, dp),
        Enzyme.Const(ctx),
    )
    loss = ret[2]
    return loss, dp
end

# ── Block-diagonal VJP (cross-validation engine) ─────────────────────────────

function _blockdiag_gradient(params::Vector{Float64}, ctx::_E2ELossContext)
    N, NT = ctx.n, ctx.nt

    positions = sgp4_series_ecef(params, ctx.epochs, ctx.ts_min, ctx.gmsts;
                                 jd_ref = ctx.jd_ref)
    loss, dP = coverage_loss_vjp(positions, ctx.ground_pts, ctx.weights;
                                 min_el = ctx.min_el, τ_cov = ctx.τ_cov,
                                 dt = ctx.dt, τ_revisit = ctx.τ_revisit,
                                 λ = ctx.λ)

    grad = similar(params)
    Threads.@threads for i in 1:N
        idx = 7 * (i - 1)
        p_i = params[idx+1:idx+7]
        epoch_i = ctx.epochs[i]
        sat_series = p -> _satellite_series_ecef(p, epoch_i, ctx.ts_min,
                                                 ctx.jd_ref, ctx.gmsts)
        cfg = ForwardDiff.JacobianConfig(sat_series, p_i, ForwardDiff.Chunk{7}())
        J_i = ForwardDiff.jacobian(sat_series, p_i, cfg)   # (3NT) × 7
        # vec(dP[i,:,:]) is (NT,3)-ordered, matching vec of the (NT,3) series.
        g_i = J_i' * vec(dP[i, :, :])
        for j in 1:7
            grad[idx+j] = g_i[j]
        end
    end

    return loss, grad
end

# ── Public gradient API ──────────────────────────────────────────────────────

"""
    sgp4_e2e_gradient(params, epochs, ts_min, ground_pts, weights;
                      jd_ref, gmsts=nothing, engine=:enzyme,
                      min_el=10.0, τ_cov=5.0, dt=nothing,
                      τ_revisit=1.0, λ=0.1) -> (loss, grad)

Loss and gradient of
`coverage_loss(sgp4_series_ecef(params, epochs, ts_min, gmsts; jd_ref), ...)`
with respect to the flat TLE parameter vector `params` (length `7N`).

Keyword arguments:
- `jd_ref` (REQUIRED): common wall-clock reference (Julian date, UTC). See the
  module header for the explicit time contract (UTC≈UT1, GMST z-rotation).
- `gmsts`: GMST per time step (rad). Computed from `jd_ref + ts_min/1440` via
  `SatelliteToolbox.jd_to_gmst` when not provided. Constant w.r.t. `params`.
- `engine`: `:enzyme` (default; one reverse pass over the whole chain) or
  `:blockdiag` (custom loss adjoint + per-satellite ForwardDiff Jacobians;
  used for cross-validation).
- `dt`: time-step spacing in minutes fed to the revisit recursion. Defaults to
  the real grid spacing `ts_min[2] − ts_min[1]` (1.0 for a single step).
- Remaining kwargs are the `coverage_loss` relaxation parameters.

The Enzyme engine runs single-threaded; the block-diagonal engine parallelizes
the per-satellite Jacobians with `Threads.@threads`.
"""
function sgp4_e2e_gradient(
    params::Vector{Float64},
    epochs,
    ts_min::AbstractVector,
    ground_pts::AbstractMatrix,
    weights::AbstractVector;
    jd_ref,
    gmsts = nothing,
    engine::Symbol = :enzyme,
    min_el::Real = 10.0,
    τ_cov::Real = 5.0,
    dt::Union{Nothing,Real} = nothing,
    τ_revisit::Real = 1.0,
    λ::Real = 0.1,
)
    _validate_sgp4_params(params)
    N = length(epochs)
    length(params) == 7N ||
        throw(ArgumentError("params length $(length(params)) ≠ 7 × $(N) epochs"))
    NT = length(ts_min)
    dt_v = dt === nothing ?
        (NT > 1 ? Float64(ts_min[2] - ts_min[1]) : 1.0) : Float64(dt)
    gmsts_v = gmsts === nothing ?
        Float64[SatelliteToolbox.jd_to_gmst(jd_ref + t / 1440.0) for t in ts_min] :
        collect(Float64, gmsts)
    length(gmsts_v) == NT ||
        throw(ArgumentError("gmsts length $(length(gmsts_v)) ≠ $(NT) time steps"))

    ctx = _E2ELossContext(
        N, NT,
        collect(Float64, epochs), Float64(jd_ref),
        collect(Float64, ts_min), gmsts_v,
        Matrix{Float64}(ground_pts), Vector{Float64}(weights),
        Float64(min_el), Float64(τ_cov), dt_v, Float64(τ_revisit), Float64(λ),
    )

    if engine === :enzyme
        return _enzyme_gradient(params, ctx)
    elseif engine === :blockdiag
        return _blockdiag_gradient(params, ctx)
    else
        throw(ArgumentError("unknown engine $engine (use :enzyme or :blockdiag)"))
    end
end

# =============================================================================
# General soft ISL adjacency (Walker-free, distance sigmoid + optional soft LOS)
# =============================================================================
# The legacy `soft_cross_plane_isl` in `soft_isl.jl` is tied to a Walker
# (P, SPP) plane structure and only counts cross-plane links. Extending the
# differentiable chain to real network KPIs needs a *general* soft adjacency
# that works for an arbitrary set of N satellites at an arbitrary instant,
# directly from ECEF positions.
#
# For a single time slice `Pt` (N×3 ECEF, km) the soft adjacency is
#
#     Ã[i,j] = σ((d_thresh − d_ij) / τ) · los_ij         (i ≠ j),   Ã[i,i] = 0
#
# with d_ij the inter-satellite Euclidean distance. `σ` is the logistic
# sigmoid; as τ → 0 the sigmoid recovers the hard range test `d_ij < d_thresh`.
# `los_ij ∈ (0,1]` is an optional smooth Earth-occlusion factor (see
# `soft_los_factor`). Everything is written as type-generic explicit loops so
# the kernels are transparent to ForwardDiff duals and to Enzyme reverse mode.
#
# Honesty note: a hard ISL link is a discontinuous {0,1} range/visibility test.
# The sigmoid/LOS relaxations are smooth proxies; first-order gradients through
# them can be unreliable exactly at the range boundary and at grazing LOS
# geometry (stiff transition), cf. Suh et al., "Do Differentiable Simulators
# Give Better Policy Gradients?", ICML 2022. Temperatures τ, τ_los trade proxy
# fidelity (small τ) against gradient smoothness (large τ).
# =============================================================================

export soft_isl_adjacency, soft_isl_adjacency!, soft_isl_edge_weights,
       soft_los_factor, hard_isl_adjacency, ISL_R_OCCLUSION_KM

# Default occlusion radius: mean Earth radius plus a thin atmosphere margin so
# that a link grazing the atmosphere is treated as blocked.
const ISL_R_OCCLUSION_KM = R_EARTH_KM + 80.0

# Numerically stable logistic: avoids Inf/Inf in Dual derivatives when |z| is large.
@inline function _sigmoid(z::T) where {T<:Number}
    if z >= zero(T)
        return one(T) / (one(T) + exp(-z))
    else
        ez = exp(z)
        return ez / (one(T) + ez)
    end
end

"""
    soft_los_factor(xi, yi, zi, xj, yj, zj; r_occ, τ_los) -> T

Smooth line-of-sight (Earth-occlusion) factor in `(0, 1]` for the segment
between satellites `i` and `j`. Computes the minimum distance from the Earth
centre to the *segment* (closest point clamped to the segment endpoints) and
maps it through a sigmoid: `σ((h_min − r_occ) / τ_los)`. It is ≈1 when the line
of sight clears the occlusion sphere and → 0 when the chord dips below it.

The endpoint clamp uses `min`/`max`; the resulting kinks (measure-zero, at the
grazing incidence where the perpendicular foot coincides with an endpoint) are
AD-transparent (ForwardDiff/Enzyme return a valid subgradient) but the sigmoid
is intentionally stiff near grazing — see the module header caveat.
"""
@inline function soft_los_factor(
    xi::T, yi::T, zi::T, xj::T, yj::T, zj::T;
    r_occ::T = T(ISL_R_OCCLUSION_KM), τ_los::T = T(50.0),
) where {T<:Number}
    dx = xj - xi; dy = yj - yi; dz = zj - zi
    L2 = dx*dx + dy*dy + dz*dz + T(1e-9)
    # foot of perpendicular from origin onto the infinite line, clamped to [0,1]
    tstar = -(xi*dx + yi*dy + zi*dz) / L2
    tc = min(max(tstar, zero(T)), one(T))
    cx = xi + tc*dx; cy = yi + tc*dy; cz = zi + tc*dz
    h = sqrt(cx*cx + cy*cy + cz*cz)
    return _sigmoid((h - r_occ) / τ_los)
end

"""
    soft_isl_adjacency(Pt; d_thresh=4000.0, τ=200.0,
                       los=false, r_occ=ISL_R_OCCLUSION_KM, τ_los=50.0) -> N×N

General soft ISL adjacency for one time slice `Pt` (N×3 ECEF, km). Returns a
symmetric `N×N` matrix with entries in `[0,1]` and zero diagonal, where
`Ã[i,j] = σ((d_thresh − d_ij)/τ)` optionally multiplied by `soft_los_factor`.
Does not depend on any Walker plane/slot structure. AD-transparent.
"""
function soft_isl_adjacency(
    Pt::AbstractMatrix{T};
    d_thresh::Real = 4000.0, τ::Real = 200.0,
    los::Bool = false, r_occ::Real = ISL_R_OCCLUSION_KM, τ_los::Real = 50.0,
) where {T<:Number}
    N = size(Pt, 1)
    A = zeros(T, N, N)
    soft_isl_adjacency!(A, Pt; d_thresh=d_thresh, τ=τ, los=los, r_occ=r_occ, τ_los=τ_los)
    return A
end

"""
    soft_isl_adjacency!(A, Pt; kwargs...) -> A

In-place variant filling a preallocated `N×N` matrix `A`. See
[`soft_isl_adjacency`](@ref). `A` must be exactly `N×N` (`N = size(Pt, 1)`);
the loops below are `@inbounds`, so this is checked explicitly rather than
relying on a `BoundsError` (a too-small `A` would otherwise silently corrupt
memory instead of erroring).
"""
function soft_isl_adjacency!(
    A::AbstractMatrix{T}, Pt::AbstractMatrix{T};
    d_thresh::Real = 4000.0, τ::Real = 200.0,
    los::Bool = false, r_occ::Real = ISL_R_OCCLUSION_KM, τ_los::Real = 50.0,
) where {T<:Number}
    N = size(Pt, 1)
    size(Pt, 2) == 3 || throw(ArgumentError("Pt must have size N×3"))
    size(A) == (N, N) ||
        throw(ArgumentError("soft_isl_adjacency!: A has size $(size(A)), expected ($N, $N) to match Pt's $N satellites"))
    d_thresh > 0 || throw(ArgumentError("d_thresh must be positive"))
    τ > 0 || throw(ArgumentError("τ must be positive"))
    r_occ > 0 || throw(ArgumentError("r_occ must be positive"))
    τ_los > 0 || throw(ArgumentError("τ_los must be positive"))
    dth = T(d_thresh); iτ = one(T) / T(τ); ro = T(r_occ); τl = T(τ_los)
    @inbounds for i in 1:N
        A[i, i] = zero(T)
        for j in (i+1):N
            dx = Pt[i,1]-Pt[j,1]; dy = Pt[i,2]-Pt[j,2]; dz = Pt[i,3]-Pt[j,3]
            d = sqrt(dx*dx + dy*dy + dz*dz)
            a = _sigmoid((dth - d) * iτ)
            if los
                a *= soft_los_factor(Pt[i,1], Pt[i,2], Pt[i,3],
                                     Pt[j,1], Pt[j,2], Pt[j,3];
                                     r_occ=ro, τ_los=τl)
            end
            A[i, j] = a
            A[j, i] = a
        end
    end
    return A
end

"""
    soft_isl_edge_weights(Pt; d_thresh=4000.0, τ=200.0, penalty_km=5.0e5,
                          los=false, r_occ=ISL_R_OCCLUSION_KM, τ_los=50.0) -> N×N

Soft routing edge-cost matrix for one time slice. Entry `W[i,j]` is the physical
propagation distance `d_ij` (km) plus a smooth barrier that penalises links that
are geometrically implausible:

    W[i,j] = d_ij + penalty_km · (1 − ã_ij),        W[i,i] = 0

where `ã_ij` is the soft adjacency value. A "good" link (`ã ≈ 1`) costs ≈ `d_ij`;
an absent link (`ã ≈ 0`) costs ≈ `d_ij + penalty_km`, i.e. is heavily
discouraged in shortest-path routing while keeping every entry finite and
differentiable (no `Inf`). Used by the soft-Bellman-Ford latency KPI.
"""
function soft_isl_edge_weights(
    Pt::AbstractMatrix{T};
    d_thresh::Real = 4000.0, τ::Real = 200.0, penalty_km::Real = 5.0e5,
    los::Bool = false, r_occ::Real = ISL_R_OCCLUSION_KM, τ_los::Real = 50.0,
) where {T<:Number}
    N = size(Pt, 1)
    size(Pt, 2) == 3 || throw(ArgumentError("Pt must have size N×3"))
    d_thresh > 0 || throw(ArgumentError("d_thresh must be positive"))
    τ > 0 || throw(ArgumentError("τ must be positive"))
    penalty_km >= 0 || throw(ArgumentError("penalty_km must be non-negative"))
    r_occ > 0 || throw(ArgumentError("r_occ must be positive"))
    τ_los > 0 || throw(ArgumentError("τ_los must be positive"))
    W = zeros(T, N, N)
    dth = T(d_thresh); iτ = one(T) / T(τ); pen = T(penalty_km)
    ro = T(r_occ); τl = T(τ_los)
    @inbounds for i in 1:N
        for j in 1:N
            i == j && continue
            dx = Pt[i,1]-Pt[j,1]; dy = Pt[i,2]-Pt[j,2]; dz = Pt[i,3]-Pt[j,3]
            d = sqrt(dx*dx + dy*dy + dz*dz)
            a = _sigmoid((dth - d) * iτ)
            if los
                a *= soft_los_factor(Pt[i,1], Pt[i,2], Pt[i,3],
                                     Pt[j,1], Pt[j,2], Pt[j,3];
                                     r_occ=ro, τ_los=τl)
            end
            W[i, j] = d + pen * (one(T) - a)
        end
    end
    return W
end

"""
    hard_isl_adjacency(Pt; d_thresh=4000.0, los=false, r_occ=ISL_R_OCCLUSION_KM)
        -> N×N

Non-differentiable reference adjacency: `A[i,j] = d_ij` when `d_ij < d_thresh`
(and, if `los`, the segment clears the occlusion sphere), otherwise `Inf`.
Diagonal is `0`. Suitable as input to `dijkstra_latency` / `network_stats` for
hard KPI baselines that the soft KPIs are compared against.
"""
function hard_isl_adjacency(
    Pt::AbstractMatrix{T};
    d_thresh::Real = 4000.0, los::Bool = false,
    r_occ::Real = ISL_R_OCCLUSION_KM,
) where {T<:Real}
    N = size(Pt, 1)
    size(Pt, 2) == 3 || throw(ArgumentError("Pt must have size N×3"))
    d_thresh > 0 || throw(ArgumentError("d_thresh must be positive"))
    r_occ > 0 || throw(ArgumentError("r_occ must be positive"))
    A = fill(T(Inf), N, N)
    dth = T(d_thresh); ro = T(r_occ)
    @inbounds for i in 1:N
        A[i, i] = zero(T)
        for j in (i+1):N
            dx = Pt[i,1]-Pt[j,1]; dy = Pt[i,2]-Pt[j,2]; dz = Pt[i,3]-Pt[j,3]
            d = sqrt(dx*dx + dy*dy + dz*dz)
            linked = d < dth
            if linked && los
                L2 = dx*dx + dy*dy + dz*dz
                tstar = -(Pt[i,1]*dx + Pt[i,2]*dy + Pt[i,3]*dz) / L2
                tc = clamp(tstar, zero(T), one(T))
                cx = Pt[i,1]+tc*dx; cy = Pt[i,2]+tc*dy; cz = Pt[i,3]+tc*dz
                linked = sqrt(cx*cx + cy*cy + cz*cz) > ro
            end
            if linked
                A[i, j] = d
                A[j, i] = d
            end
        end
    end
    return A
end

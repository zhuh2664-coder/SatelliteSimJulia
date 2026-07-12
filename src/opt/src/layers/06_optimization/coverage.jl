# =============================================================================
# Coverage and Revisit Relaxations (R1–R4)
# =============================================================================
# 来源: DifferentiableLEO/src/coverage/relaxations.jl
# 四个连续松弛函数，使覆盖和重访目标可微。
#
# 新增抽象类型层次：
#   AbstractCoverageRelaxation → SoftCoverage, NoisyORCoverage, LeakyRevisit, LogSumExpMax
# 可通过多分派扩展新的覆盖松弛策略。
# =============================================================================

# ── 抽象类型层次 ──────────────────────────────────────────────────────────────

abstract type AbstractCoverageRelaxation end

"""R1: sigmoid 软阈值替代硬仰角截止"""
Base.@kwdef struct SoftCoverage <: AbstractCoverageRelaxation
    min_elevation_deg::Float64 = 10.0
    temperature::Float64 = 5.0  # τ
end

"""R2: noisy-OR 替代 any-satellite"""
struct NoisyORCoverage <: AbstractCoverageRelaxation end

"""R3: leaky integrator 替代离散重访间隔"""
struct LeakyRevisit <: AbstractCoverageRelaxation end

"""R4: LogSumExp 软最大值替代 hard max"""
Base.@kwdef struct LogSumExpMax <: AbstractCoverageRelaxation
    temperature::Float64 = 1.0  # τ
end

# ── 多分派泛型函数 ────────────────────────────────────────────────────────────

"""
    relax(::SoftCoverage, elevation_deg, min_el_deg; τ) -> T
    relax(::NoisyORCoverage, coverages) -> T
    relax(::LeakyRevisit, gap, dt, coverage) -> T
    relax(::LogSumExpMax, values; τ) -> T

各覆盖松弛策略的统一多分派接口。
"""
function relax end

# ── R1: Soft sigmoid elevation threshold ──────────────────────────────────────

function relax(::SoftCoverage, elevation_deg::T, min_el_deg::T; τ::T = T(5.0)) where T <: Number
    z = (elevation_deg - min_el_deg) / τ
    return one(T) / (one(T) + exp(-z))
end

"""
    soft_coverage(elevation_deg, min_el_deg; τ=5.0) -> T

R1 relaxation: hard elevation cutoff → sigmoid σ((el − min_el)/τ).
The value is exactly 0.5 at the cutoff for any τ; τ controls the transition
width (≈0.88 at min_el + 2τ, ≈0.12 at min_el − 2τ).
Type-generic: works with Float64 and Enzyme/ForwardDiff dual numbers.
"""
function soft_coverage(elevation_deg::T, min_el_deg::T; τ::T = T(5.0)) where T <: Number
    # SoftCoverage 仅作分派 token（relax 只读显式实参）；用默认字段构造，
    # 避免把 ForwardDiff Dual 塞进 Float64 字段。
    return relax(SoftCoverage(), elevation_deg, min_el_deg; τ=τ)
end

# ── R2: Noisy-OR multi-satellite aggregation ──────────────────────────────────

function relax(::NoisyORCoverage, coverages::AbstractVector{T}) where T <: Number
    p_none = one(T)
    for c in coverages
        p_none *= (one(T) - c)
    end
    return one(T) - p_none
end

"""
    noisy_or_coverage(coverages) -> T

R2 relaxation: any-satellite coverage → noisy-OR.
"""
function noisy_or_coverage(coverages::AbstractVector{T}) where T <: Number
    return relax(NoisyORCoverage(), coverages)
end

# ── R3: Leaky integrator for revisit tracking ─────────────────────────────────

function relax(::LeakyRevisit, gap::T, dt::T, coverage::T) where T <: Number
    return (gap + dt) * (one(T) - coverage)
end

"""
    leaky_revisit(gap, dt, coverage) -> T

R3 relaxation: discrete revisit gap → leaky integrator.
"""
function leaky_revisit(gap::T, dt::T, coverage::T) where T <: Number
    return relax(LeakyRevisit(), gap, dt, coverage)
end

# ── R4: LogSumExp soft-maximum ────────────────────────────────────────────────

function relax(::LogSumExpMax, values::AbstractVector{T}; τ::T = one(T)) where T <: Number
    mx = maximum(values)
    return mx + τ * log(sum(exp.((values .- mx) ./ τ)))
end

"""
    logsumexp_max(values; τ=1.0) -> T

R4 relaxation: max → LogSumExp soft-maximum.
"""
function logsumexp_max(values::AbstractVector{T}; τ::T = one(T)) where T <: Number
    # 同上：token 用默认字段构造，保持 ForwardDiff Dual 安全。
    return relax(LogSumExpMax(), values; τ=τ)
end

# ── Internal: elevation angle computation ─────────────────────────────────────

"""
    _elevation_deg(sx, sy, sz, gx, gy, gz) -> T

Elevation angle (degrees) from ground point to satellite.
Uses atan2 instead of asin to avoid derivative singularity at zenith.
"""
function _elevation_deg(sx::T, sy::T, sz::T, gx::T, gy::T, gz::T) where T <: Number
    dx, dy, dz = sx - gx, sy - gy, sz - gz
    gr  = sqrt(gx^2 + gy^2 + gz^2)
    nx, ny, nz = gx / gr, gy / gr, gz / gr
    along_normal = dx * nx + dy * ny + dz * nz
    tx = dx - along_normal * nx
    ty = dy - along_normal * ny
    tz = dz - along_normal * nz
    tangential = sqrt(tx^2 + ty^2 + tz^2 + T(1e-12))
    el_rad = atan(along_normal, tangential)
    return el_rad * T(180.0 / π)
end

# ── Ground grid (real-surface ECEF) ───────────────────────────────────────────

"""
    ground_grid(n_lat, n_lon; lat_bounds=(-70.0,70.0), radius_km=R_EARTH_KM) -> (points, weights)

Generate a latitude–longitude ground grid as real-surface ECEF coordinates.
Returns (G×3 matrix, G-vector of cos(lat) weights).
"""
function ground_grid(n_lat::Int, n_lon::Int;
                     lat_bounds::Tuple{Float64,Float64} = (-70.0, 70.0),
                     radius_km::Float64 = R_EARTH_KM)
    lats = range(deg2rad(lat_bounds[1]), deg2rad(lat_bounds[2]); length = n_lat)
    lons = range(deg2rad(-180.0), deg2rad(180.0); length = n_lon + 1)[1:end-1]
    G = n_lat * n_lon
    pts = Matrix{Float64}(undef, G, 3)
    wts = Vector{Float64}(undef, G)
    idx = 1
    for φ in lats, λ in lons
        cφ = cos(φ)
        pts[idx, 1] = radius_km * cφ * cos(λ)
        pts[idx, 2] = radius_km * cφ * sin(λ)
        pts[idx, 3] = radius_km * sin(φ)
        wts[idx] = cφ
        idx += 1
    end
    return pts, wts
end

# ── Combined coverage + revisit loss ──────────────────────────────────────────

"""
    coverage_loss(positions, ground_pts, weights; min_el, τ_cov, dt, τ_revisit, λ) -> T

Combined loss: L = -mean_coverage + λ · worst_revisit_gap
"""
function coverage_loss(
    positions::AbstractArray{T,3},     # N×NT×3
    ground_pts::AbstractMatrix{T},     # G×3
    weights::AbstractVector{T};
    min_el::T   = T(10.0),
    τ_cov::T    = T(5.0),
    dt::T       = T(1.0),
    τ_revisit::T = one(T),
    λ::T        = T(0.1),
) where T <: Number
    N, NT, _ = size(positions)
    G = size(ground_pts, 1)

    total_cov    = zero(T)
    total_weight = zero(T)
    revisit_gaps = Vector{T}(undef, G)

    for g in 1:G
        gx, gy, gz = ground_pts[g, 1], ground_pts[g, 2], ground_pts[g, 3]
        w = weights[g]

        step_cov = Vector{T}(undef, NT)
        for ti in 1:NT
            sat_covs = Vector{T}(undef, N)
            for sat in 1:N
                sx, sy, sz = positions[sat, ti, 1], positions[sat, ti, 2], positions[sat, ti, 3]
                el = _elevation_deg(sx, sy, sz, gx, gy, gz)
                sat_covs[sat] = soft_coverage(el, min_el; τ = τ_cov)
            end
            cov_t = noisy_or_coverage(sat_covs)
            step_cov[ti] = cov_t
            total_cov    += cov_t * w
            total_weight += w
        end

        gap = zero(T)
        for ti in 1:NT
            gap = leaky_revisit(gap, dt, step_cov[ti])
        end
        revisit_gaps[g] = gap * w
    end

    mean_cov      = total_cov / total_weight
    worst_revisit = logsumexp_max(revisit_gaps; τ = τ_revisit)
    return -mean_cov + λ * worst_revisit
end

# ── Multi-layer (K-fold) coverage depth loss ──────────────────────────────────

"""
    coverage_depth_loss(raans, mas, inc_rad, alt_km, ground_pts, weights, t_steps;
                        min_el, τ_cov, target_K) -> T

K-fold coverage depth objective with diminishing returns saturating at target_K.
"""
function coverage_depth_loss(
    raans::AbstractVector{T},
    mas::AbstractVector{T},
    inc_rad::T,
    alt_km::T,
    ground_pts::AbstractMatrix{T},
    weights::AbstractVector{T},
    t_steps::AbstractVector{T};
    min_el::T    = T(10.0),
    τ_cov::T     = T(5.0),
    target_K::T  = one(T),
) where T <: Number
    NT = length(t_steps)
    N  = length(mas)
    G  = size(ground_pts, 1)

    total        = zero(T)
    total_weight = zero(T)

    for g in 1:G
        gx = ground_pts[g, 1]
        gy = ground_pts[g, 2]
        gz = ground_pts[g, 3]
        w  = weights[g]

        for ti in 1:NT
            t   = t_steps[ti]
            pos = constellation_positions(raans, mas, inc_rad, alt_km, t)

            depth = zero(T)
            for i in 1:N
                el    = _elevation_deg(pos[i, 1], pos[i, 2], pos[i, 3], gx, gy, gz)
                depth += soft_coverage(el, min_el; τ = τ_cov)
            end

            effective = target_K * (one(T) - exp(-depth / target_K))
            total        -= effective * w
            total_weight += w
        end
    end

    return total / total_weight / NT
end

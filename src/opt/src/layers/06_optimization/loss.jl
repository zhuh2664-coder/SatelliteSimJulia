# =============================================================================
# Layer 4 — Differentiable Loss Function
# =============================================================================
# 来源: DifferentiableLEO/src/optimize/loss.jl
# 端到端可微损失：轨道参数 → 覆盖 (R1-R4) → 标量损失。
# Enzyme 对此函数求 ∂L/∂raans。
#
# 新增抽象类型：AbstractDifferentiableLoss → CoverageLoss, EndToEndLoss
# =============================================================================

abstract type AbstractDifferentiableLoss end

"""覆盖损失：-mean_coverage + λ · worst_revisit_gap"""
Base.@kwdef struct CoverageLoss <: AbstractDifferentiableLoss
    ground_pts::Matrix{Float64}
    weights::Vector{Float64}
    min_elevation::Float64 = 10.0
    coverage_temperature::Float64 = 5.0
    dt::Float64 = 1.0
    revisit_temperature::Float64 = 1.0
    revisit_lambda::Float64 = 0.1
end

"""端到端损失：与 CoverageLoss 相同结构，使用不同参数"""
Base.@kwdef struct EndToEndLoss <: AbstractDifferentiableLoss
    ground_pts::Matrix{Float64}
    weights::Vector{Float64}
    t_steps::Vector{Float64}
    min_elevation::Float64 = 10.0
    coverage_temperature::Float64 = 5.0
    dt::Float64 = 1.0
    revisit_temperature::Float64 = 1.0
    revisit_lambda::Float64 = 0.1
end

"""
    end_to_end_loss(raans, mas, inc_rad, alt_km, ground_pts, weights,
                    t_steps; min_el, τ_cov, dt, τ_revisit, λ) -> T

End-to-end differentiable loss. This is THE function Enzyme differentiates.
"""
function end_to_end_loss(
    raans::AbstractVector{T},
    mas::AbstractVector{T},
    inc_rad::T,
    alt_km::T,
    ground_pts::AbstractMatrix{T},
    weights::AbstractVector{T},
    t_steps::AbstractVector{T};
    min_el::T    = T(10.0),
    τ_cov::T     = T(5.0),
    dt::T        = T(1.0),
    τ_revisit::T = one(T),
    λ::T         = T(0.1),
) where T <: Number
    NT = length(t_steps)
    N  = length(mas)
    G  = size(ground_pts, 1)

    total_cov    = zero(T)
    total_weight = zero(T)
    revisit_gaps = Vector{T}(undef, G)

    for g in 1:G
        gx = ground_pts[g, 1]
        gy = ground_pts[g, 2]
        gz = ground_pts[g, 3]
        w  = weights[g]

        step_cov = Vector{T}(undef, NT)
        for ti in 1:NT
            t = t_steps[ti]
            pos = constellation_positions(raans, mas, inc_rad, alt_km, t)

            sat_covs = Vector{T}(undef, N)
            for sat in 1:N
                el = _elevation_deg(pos[sat, 1], pos[sat, 2], pos[sat, 3], gx, gy, gz)
                sat_covs[sat] = soft_coverage(el, min_el; τ = τ_cov)
            end

            cov_t = noisy_or_coverage(sat_covs)
            step_cov[ti] = cov_t
            total_cov    += cov_t * w
            total_weight += w
        end

        gap  = zero(T)
        gaps = Vector{T}(undef, NT)
        for ti in 1:NT
            gap = leaky_revisit(gap, dt, step_cov[ti])
            gaps[ti] = gap
        end
        revisit_gaps[g] = logsumexp_max(gaps; τ = τ_revisit) * w
    end

    mean_cov     = total_cov / total_weight
    mean_revisit = sum(revisit_gaps) / sum(weights)
    return -mean_cov + λ * mean_revisit
end

"""
    deadzone_scan_loss(Δω_deg, base_raan, P, SPP, F, inc_rad, alt_km, t_steps; d_thresh)

Compute average cross-plane ISL count for given RAAN gap ΔΩ.
Used for Figure 1 (dead zone scan). Non-differentiable (Float64).
"""
function deadzone_scan_loss(
    Δω_deg::Float64,
    base_raan::Float64,
    P::Int,
    SPP::Int,
    F::Int,
    inc_rad::Float64,
    alt_km::Float64,
    t_steps::AbstractVector{Float64};
    d_thresh::Float64 = 4000.0,
)
    raans = Float64[base_raan, mod(base_raan + Δω_deg, 360.0)]
    mas   = walker_mas(2, SPP, F)

    total_isl = 0.0
    for t in t_steps
        pos = constellation_positions(raans, mas, inc_rad, alt_km, t)
        total_isl += cross_plane_isl_count(pos, 2, SPP; d_thresh = d_thresh)
    end
    return total_isl / length(t_steps)
end

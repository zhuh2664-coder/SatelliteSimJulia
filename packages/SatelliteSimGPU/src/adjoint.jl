# 自定义伴随（custom adjoint）
#
# 给 coverage_loss_gpu 写 ChainRules rrule，使其对 positions 可微（Zygote/Enzyme
# 通过 ChainRules 规则即可反传），无需把自定义 @kernel 交给 AD 直接穿透。
#
# 反向拆两段：
#   1. 便宜的 (G×NT) 段（mean + leaky-revisit + LogSumExp）在 host 上算出 d_step_cov —— 标量、易验证；
#   2. 昂贵的 (N×G×NT) 段（d_step_cov → d_positions，经 noisy-OR、sigmoid、仰角梯度）用 GPU 反向核。
#
# 仰角对卫星位置的解析梯度见 _elevation_deg_grad_gpu；整体对有限差分验证。

export coverage_step_gpu

# ── 仰角对卫星位置的解析梯度（对齐 _elevation_deg_gpu）─────────────────────────
# el_rad = atan(along, tang);  along = d·n;  tang = |d - along·n|（n=g/|g|, d=s-g）
# d(el_rad)/ds = (tang·n - along·(tvec/tang)) / (along² + tang²)
@inline function _elevation_deg_grad_gpu(
    sx::T, sy::T, sz::T, gx::T, gy::T, gz::T,
) where {T<:AbstractFloat}
    dx, dy, dz = sx - gx, sy - gy, sz - gz
    gr = sqrt(gx * gx + gy * gy + gz * gz)
    nx, ny, nz = gx / gr, gy / gr, gz / gr
    along = dx * nx + dy * ny + dz * nz
    tvx = dx - along * nx
    tvy = dy - along * ny
    tvz = dz - along * nz
    tang = sqrt(tvx * tvx + tvy * tvy + tvz * tvz + T(1e-12))
    denom = along * along + tang * tang
    k = T(180.0 / π) / denom
    gxo = k * (tang * nx - along * tvx / tang)
    gyo = k * (tang * ny - along * tvy / tang)
    gzo = k * (tang * nz - along * tvz / tang)
    return gxo, gyo, gzo
end

"""
    coverage_step_gpu(positions, ground_pts; min_el, τ_cov) -> step_cov (G×NT)

设备原生：逐 (ground, time) 的 noisy-OR 软覆盖率。复用前向覆盖核。
"""
function coverage_step_gpu(
    positions::AbstractArray{T,3},
    ground_pts::AbstractMatrix{T};
    min_el::T=T(10.0),
    τ_cov::T=T(5.0),
) where {T<:AbstractFloat}
    n_satellites, n_times, _ = size(positions)
    n_ground = size(ground_pts, 1)
    backend = get_backend(positions)
    step_cov = similar(positions, T, (n_ground, n_times))
    _wait_event(_coverage_kernel!(backend)(
        step_cov, positions, ground_pts, min_el, τ_cov, n_satellites, n_times;
        ndrange=n_ground * n_times,
    ))
    return step_cov
end

# host 反向：由 step_cov 求 d(loss)/d(step_cov)（mean + leaky-revisit + LSE）。
function _coverage_dstepcov(
    step_cov::Matrix{Float64},
    weights::Vector{Float64};
    dt::Float64, τ_revisit::Float64, λ::Float64, ȳ::Float64,
)
    G, NT = size(step_cov)
    total_w = sum(weights)
    dsc = Matrix{Float64}(undef, G, NT)

    # mean 部分：dL/dstep = ȳ·(-1)·w_g/(Σw·NT)
    mean_coef = -ȳ / (total_w * NT)
    @inbounds for g in 1:G, t in 1:NT
        dsc[g, t] = mean_coef * weights[g]
    end

    # revisit 前向：gap 递推 + rg = gap·w
    gaps = Matrix{Float64}(undef, G, NT)
    rg = Vector{Float64}(undef, G)
    @inbounds for g in 1:G
        gp = 0.0
        for t in 1:NT
            gp = (gp + dt) * (1.0 - step_cov[g, t])
            gaps[g, t] = gp
        end
        rg[g] = gp * weights[g]
    end

    # LSE softmax = ∂worst_revisit/∂rg
    m = maximum(rg)
    ex = exp.((rg .- m) ./ τ_revisit)
    sm = ex ./ sum(ex)

    # revisit backward：穿过 leaky 递推
    @inbounds for g in 1:G
        d_gapfinal = ȳ * λ * sm[g] * weights[g]  # rg = gap·w
        dgap = d_gapfinal
        for t in NT:-1:1
            gap_prev = t == 1 ? 0.0 : gaps[g, t - 1]
            # gap_t = (gap_prev+dt)·(1-sc_t)
            dsc[g, t] += dgap * (-(gap_prev + dt))
            dgap *= (1.0 - step_cov[g, t])
        end
    end
    return dsc
end

# GPU 反向核：d_step_cov (G×NT) → grad_pos (N×NT×3)
@kernel function _coverage_backward_kernel!(
    grad_pos, positions, ground_pts, step_cov, d_step_cov,
    min_el, τ_cov, n_ground, n_times,
)
    linear = @index(Global)
    linear -= 1
    time_index = linear % n_times + 1
    sat_index = linear ÷ n_times + 1
    T = eltype(grad_pos)

    sx = positions[sat_index, time_index, 1]
    sy = positions[sat_index, time_index, 2]
    sz = positions[sat_index, time_index, 3]

    gxa = zero(T)
    gya = zero(T)
    gza = zero(T)
    inv_tau = one(T) / τ_cov

    for g in 1:n_ground
        gx = ground_pts[g, 1]
        gy = ground_pts[g, 2]
        gz = ground_pts[g, 3]
        elev = _elevation_deg_gpu(sx, sy, sz, gx, gy, gz)
        z = (elev - min_el) / τ_cov
        c = one(T) / (one(T) + exp(-z))
        one_minus_c = one(T) - c
        # ∂step_cov/∂c_s = Π_{s'≠s}(1-c') = (1-step_cov)/(1-c)
        prod_excl = (one(T) - step_cov[g, time_index]) / one_minus_c
        dc_dz = c * one_minus_c
        egx, egy, egz = _elevation_deg_grad_gpu(sx, sy, sz, gx, gy, gz)
        coef = d_step_cov[g, time_index] * prod_excl * dc_dz * inv_tau
        gxa += coef * egx
        gya += coef * egy
        gza += coef * egz
    end

    grad_pos[sat_index, time_index, 1] = gxa
    grad_pos[sat_index, time_index, 2] = gya
    grad_pos[sat_index, time_index, 3] = gza
end

"""
    _coverage_grad_positions(positions, ground_pts, step_cov, d_step_cov; min_el, τ_cov)

由 host 端 d_step_cov 求 grad_pos（设备核）。
"""
function _coverage_grad_positions(
    positions::AbstractArray{T,3},
    ground_pts::AbstractMatrix{T},
    step_cov,
    d_step_cov_host::Matrix{Float64};
    min_el::T, τ_cov::T,
) where {T<:AbstractFloat}
    n_satellites, n_times, _ = size(positions)
    n_ground = size(ground_pts, 1)
    backend = get_backend(positions)
    d_step_cov = adapt(backend, T.(d_step_cov_host))
    grad_pos = similar(positions)
    _wait_event(_coverage_backward_kernel!(backend)(
        grad_pos, positions, ground_pts, step_cov, d_step_cov,
        min_el, τ_cov, n_ground, n_times;
        ndrange=n_satellites * n_times,
    ))
    return grad_pos
end

# ── ChainRules rrule：coverage_loss_gpu 对 positions 可微 ──────────────────────
function ChainRulesCore.rrule(
    ::typeof(coverage_loss_gpu),
    positions::AbstractArray{T,3},
    ground_pts::AbstractMatrix{T},
    weights::AbstractVector{T};
    min_el::T=T(10.0),
    τ_cov::T=T(5.0),
    dt::T=T(1.0),
    τ_revisit::T=one(T),
    λ::T=T(0.1),
) where {T<:AbstractFloat}
    y = coverage_loss_gpu(
        positions, ground_pts, weights;
        min_el=min_el, τ_cov=τ_cov, dt=dt, τ_revisit=τ_revisit, λ=λ,
    )
    step_cov = coverage_step_gpu(positions, ground_pts; min_el=min_el, τ_cov=τ_cov)

    function coverage_loss_gpu_pullback(ȳ)
        sc_host = Float64.(Array(step_cov))
        w_host = Float64.(Array(weights))
        dsc = _coverage_dstepcov(
            sc_host, w_host;
            dt=Float64(dt), τ_revisit=Float64(τ_revisit),
            λ=Float64(λ), ȳ=Float64(ȳ),
        )
        grad_pos = _coverage_grad_positions(
            positions, ground_pts, step_cov, dsc; min_el=min_el, τ_cov=τ_cov,
        )
        return (NoTangent(), grad_pos, NoTangent(), NoTangent())
    end

    return y, coverage_loss_gpu_pullback
end

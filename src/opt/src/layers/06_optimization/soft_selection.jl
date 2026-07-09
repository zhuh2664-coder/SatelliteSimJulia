# =============================================================================
# Differentiable Soft Beam-Selection — Path 2 研究方向
# =============================================================================
# 来源: DifferentiableLEO/src/network/soft_selection.jl
# 可微的卫星-地面波束配对优化。在每颗卫星波束预算 B 约束下，
# 联合优化所有小区的波束分配以最大化总容量。
# =============================================================================

# ── Symmetric 3×3 logdet (Enzyme-safe) ────────────────────────────────────────

@inline function logdet_sym3(a11::T, a22::T, a33::T,
                             a12::T, a13::T, a23::T) where T<:Number
    det = a11*(a22*a33 - a23*a23) -
          a12*(a12*a33 - a23*a13) +
          a13*(a12*a23 - a22*a13)
    det_safe = max(det, eps(T))
    return log(det_safe)
end

# ── Visibility precompute (Float64, outside AD) ──────────────────────────────

function build_visibility(pos::Matrix{Float64}, ground_pts::Matrix{Float64};
                          min_el::Float64 = 10.0)
    N = size(pos, 1)
    G = size(ground_pts, 1)
    dirs = Vector{NTuple{3,Float64}}()
    sats = Vector{Int}()
    cell_ptr = Vector{Int}(undef, G+1)
    cell_ptr[1] = 1
    for g in 1:G
        gx, gy, gz = ground_pts[g,1], ground_pts[g,2], ground_pts[g,3]
        gr = max(sqrt(gx*gx + gy*gy + gz*gz), eps())
        upx, upy, upz = gx/gr, gy/gr, gz/gr
        for i in 1:N
            dx = pos[i,1]-gx; dy = pos[i,2]-gy; dz = pos[i,3]-gz
            d = max(sqrt(dx*dx + dy*dy + dz*dz), eps())
            ux, uy, uz = dx/d, dy/d, dz/d
            el = asind(clamp(ux*upx + uy*upy + uz*upz, -1.0, 1.0))
            if el >= min_el
                push!(dirs, (ux, uy, uz))
                push!(sats, i)
            end
        end
        cell_ptr[g+1] = length(dirs) + 1
    end
    npairs = length(dirs)
    dir = Matrix{Float64}(undef, npairs, 3)
    sat_of = Vector{Int}(undef, npairs)
    for p in 1:npairs
        dir[p,1], dir[p,2], dir[p,3] = dirs[p]
        sat_of[p] = sats[p]
    end
    return cell_ptr, dir, sat_of, npairs
end

# ── Differentiable soft-assignment capacity ───────────────────────────────────

function soft_select_capacity(logits::AbstractVector{T},
                              cell_ptr::Vector{Int},
                              dir::Matrix{Float64},
                              sat_of::Vector{Int},
                              nsats::Int;
                              snr::T = T(10.0),
                              B::T = T(4.0),
                              λ_beam::T = T(1.0),
                              weights::Vector{Float64} = Float64[]) where T<:Number
    G = length(cell_ptr) - 1
    use_w = !isempty(weights)

    load = zeros(T, nsats)
    total_cap = zero(T)
    for g in 1:G
        lo = cell_ptr[g]; hi = cell_ptr[g+1] - 1
        hi < lo && continue
        r11 = zero(T); r22 = zero(T); r33 = zero(T)
        r12 = zero(T); r13 = zero(T); r23 = zero(T)
        m = zero(T)
        for p in lo:hi
            a = one(T) / (one(T) + exp(-logits[p]))
            ux = T(dir[p,1]); uy = T(dir[p,2]); uz = T(dir[p,3])
            r11 += a*ux*ux; r22 += a*uy*uy; r33 += a*uz*uz
            r12 += a*ux*uy; r13 += a*ux*uz; r23 += a*uy*uz
            m   += a
            load[sat_of[p]] += a
        end
        α = snr / (m + T(1e-9))
        c = logdet_sym3(one(T) + α*r11, one(T) + α*r22, one(T) + α*r33,
                        α*r12, α*r13, α*r23)
        total_cap += use_w ? T(weights[g])*c : c
    end

    penalty = zero(T)
    for i in 1:nsats
        ex = load[i] - B
        if ex > zero(T)
            penalty += ex*ex
        end
    end

    return -(total_cap - λ_beam * penalty)
end

# ── Hard baselines (non-differentiable, Float64) ──────────────────────────────

function _hard_cap(chosen::Vector{Int}, dir::Matrix{Float64}, snr::Float64)
    m = length(chosen)
    m == 0 && return 0.0
    r11=0.0;r22=0.0;r33=0.0;r12=0.0;r13=0.0;r23=0.0
    for p in chosen
        ux,uy,uz = dir[p,1],dir[p,2],dir[p,3]
        r11+=ux*ux;r22+=uy*uy;r33+=uz*uz;r12+=ux*uy;r13+=ux*uz;r23+=uy*uz
    end
    α = snr/m
    return logdet_sym3(1.0+α*r11, 1.0+α*r22, 1.0+α*r33, α*r12, α*r13, α*r23)
end

function hard_eval_topM(cell_ptr, dir, sat_of, els, nsats;
                        M::Int, B::Int, snr::Float64, weights::Vector{Float64})
    G = length(cell_ptr) - 1
    beam_used = zeros(Int, nsats)
    total = 0.0
    for g in 1:G
        lo = cell_ptr[g]; hi = cell_ptr[g+1]-1
        hi < lo && continue
        order = sort(lo:hi; by = p -> -els[p])
        chosen = Int[]
        for p in order
            length(chosen) >= M && break
            beam_used[sat_of[p]] >= B && continue
            push!(chosen, p); beam_used[sat_of[p]] += 1
        end
        total += weights[g] * _hard_cap(chosen, dir, snr)
    end
    return total
end

function hard_eval_diversity(cell_ptr, dir, sat_of, els, nsats;
                             M::Int, B::Int, snr::Float64, weights::Vector{Float64})
    G = length(cell_ptr) - 1
    beam_used = zeros(Int, nsats)
    total = 0.0
    for g in 1:G
        lo = cell_ptr[g]; hi = cell_ptr[g+1]-1
        hi < lo && continue
        chosen = Int[]
        first_p = 0; best_el = -Inf
        for p in lo:hi
            beam_used[sat_of[p]] >= B && continue
            if els[p] > best_el; best_el = els[p]; first_p = p; end
        end
        first_p == 0 && continue
        push!(chosen, first_p); beam_used[sat_of[first_p]] += 1
        while length(chosen) < M
            best_p = 0; best_corr = Inf
            for p in lo:hi
                p in chosen && continue
                beam_used[sat_of[p]] >= B && continue
                maxc = 0.0
                for c in chosen
                    corr = abs(dir[p,1]*dir[c,1] + dir[p,2]*dir[c,2] + dir[p,3]*dir[c,3])
                    corr > maxc && (maxc = corr)
                end
                if maxc < best_corr; best_corr = maxc; best_p = p; end
            end
            best_p == 0 && break
            push!(chosen, best_p); beam_used[sat_of[best_p]] += 1
        end
        total += weights[g] * _hard_cap(chosen, dir, snr)
    end
    return total
end

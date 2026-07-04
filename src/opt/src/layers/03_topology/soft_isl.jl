# =============================================================================
# Layer 2 — ISL Topology (Dense O(N²) + Soft Sigmoid)
# =============================================================================
# 来源: DifferentiableLEO/src/network/topology.jl
# 提供硬阈值 ISL 邻接矩阵 + 可微软 cross-plane ISL 计数。
#
# 集成到 Platform 多分派体系：
#   SoftThresholdISLTopology <: AbstractTopologyStrategy (如果 Platform 已加载)
#   否则作为独立函数使用。
# =============================================================================

const INF_DIST = Inf

# ── 几何辅助函数 ──────────────────────────────────────────────────────────────

@inline function _dist(positions::AbstractMatrix, i::Int, j::Int)
    dx = positions[i, 1] - positions[j, 1]
    dy = positions[i, 2] - positions[j, 2]
    dz = positions[i, 3] - positions[j, 3]
    return sqrt(dx^2 + dy^2 + dz^2)
end

# ── 硬 ISL 邻接矩阵 ───────────────────────────────────────────────────────────

"""
    isl_adjacency(positions, P, SPP; d_thresh) -> Matrix

Build ISL adjacency matrix: intra-plane ±1 ring + cross-plane distance threshold.
Returns N×N symmetric matrix (Inf = no link).
"""
function isl_adjacency(
    positions::AbstractMatrix{T},
    P::Int,
    SPP::Int;
    d_thresh::T = T(4000.0),
) where T <: Number
    N = P * SPP
    A = fill(T(INF_DIST), N, N)

    for i in 1:N
        pi = (i - 1) ÷ SPP + 1
        si = (i - 1) % SPP

        for j in (i + 1):N
            pj = (j - 1) ÷ SPP + 1
            sj = (j - 1) % SPP

            dist = _dist(positions, i, j)

            if pi == pj
                # Intra-plane: ±1 ring topology
                if mod(si - sj + SPP, SPP) == 1 || mod(sj - si + SPP, SPP) == 1
                    A[i, j] = dist
                    A[j, i] = dist
                end
            else
                # Cross-plane: distance threshold
                if dist < d_thresh
                    A[i, j] = dist
                    A[j, i] = dist
                end
            end
        end
    end
    return A
end

"""
    cross_plane_isl_count(positions, P, SPP; d_thresh) -> Float64

Count active cross-plane ISL links. Used for dead zone scan.
"""
function cross_plane_isl_count(
    positions::AbstractMatrix{T},
    P::Int,
    SPP::Int;
    d_thresh::T = T(4000.0),
) where T <: Number
    N = P * SPP
    count = zero(T)
    for i in 1:N
        pi = (i - 1) ÷ SPP + 1
        for j in (i + 1):N
            pj = (j - 1) ÷ SPP + 1
            if pi != pj
                dist = _dist(positions, i, j)
                if dist < d_thresh
                    count += one(T)
                end
            end
        end
    end
    return count
end

# ── 可微软 cross-plane ISL ───────────────────────────────────────────────────

"""
    soft_cross_plane_isl(positions, P, SPP; d_thresh, τ) -> T

Differentiable proxy for cross_plane_isl_count. Each cross-plane pair contributes
sigmoid((d_thresh - dist)/τ) ∈ (0,1). As τ→0 recovers hard count.
"""
function soft_cross_plane_isl(positions::AbstractMatrix{T}, P::Int, SPP::Int;
                              d_thresh::T = T(4000.0), τ::T = T(200.0)) where T <: Number
    N = P * SPP
    total = zero(T)
    for i in 1:N
        pi = (i - 1) ÷ SPP
        for j in (i + 1):N
            pj = (j - 1) ÷ SPP
            if pi != pj
                d = _dist(positions, i, j)
                total += one(T) / (one(T) + exp((d - d_thresh) / τ))
            end
        end
    end
    return total
end

# ── 多分派集成: SoftThresholdISLTopology ──────────────────────────────────────

"""
    SoftThresholdISLTopology

软阈值 ISL 拓扑策略。如果 Platform 的 AbstractTopologyStrategy 可用，
自动成为其子类型；否则作为独立策略使用。

字段:
- distance_threshold_km : 跨面 ISL 距离阈值 (默认 4000 km)
- sigmoid_temperature : sigmoid 温度参数 (默认 200 km)
"""
Base.@kwdef struct SoftThresholdISLTopology
    distance_threshold_km::Float64 = 4000.0
    sigmoid_temperature::Float64 = 200.0
end

# Grid+ 拓扑。每颗卫星 4 条固定 ISL（2 面内 + 2 面间）。
# Iridium / Starlink 基线。

export GridPlusStrategy

struct GridPlusStrategy <: AbstractTopologyStrategy end

function generate_topology(::GridPlusStrategy, T::Int, P::Int)::TopologyOutput
    links = generate_isl_candidates(T, P)
    return TopologyOutput(links, Tuple{Int,Int}[], "Grid+")
end

# O(1) 查询，无需构建整个拓扑
function isl_neighbors(::GridPlusStrategy, sat_id::Int, T::Int, P::Int)::Vector{Int}
    S = div(T, P)
    plane = (sat_id - 1) ÷ S + 1
    slot  = (sat_id - 1) % S + 1

    # Intra-plane ±1 neighbors (ring wrap)
    prev_slot = mod1(slot - 1, S)
    next_slot = mod1(slot + 1, S)
    intra = [(plane - 1) * S + prev_slot, (plane - 1) * S + next_slot]

    # Inter-plane: same slot in adjacent planes (wrap)
    left_plane  = mod1(plane - 1, P)
    right_plane = mod1(plane + 1, P)
    inter = [(left_plane - 1) * S + slot, (right_plane - 1) * S + slot]

    return sort(vcat(intra, inter))
end

# Grid+ 总是 2T 条边: T/2 × 2 intra + T/2 × 2 inter
function num_isl(::GridPlusStrategy, T::Int, P::Int)::Int
    return T * 2
end

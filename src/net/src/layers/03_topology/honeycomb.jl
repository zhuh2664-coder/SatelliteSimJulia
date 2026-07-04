# 蜂窝（3-ISL）拓扑。每颗卫星 3 条 ISL（2 面内 + 1 交替面间）。
# 面间按 (plane+slot) 奇偶剪枝，形成蜂窝结构。参考 IEEE TAES 2025。

export HoneycombStrategy

struct HoneycombStrategy <: AbstractTopologyStrategy end

function generate_topology(::HoneycombStrategy, T::Int, P::Int)::TopologyOutput
    S = div(T, P)
    links = Tuple{Int,Int}[]

    # 面内 ring：每个平面调用 generate_intra_plane_links
    for p in 1:P
        offset = (p - 1) * S
        for (i, j) in generate_intra_plane_links(S)
            push!(links, (i + offset, j + offset))
        end
    end

    # 面间：相邻面同 slot，仅在 (p + s) 为偶数时连右邻居（奇偶剪枝）
    for p in 1:P
        q = mod1(p + 1, P)
        p == q && continue
        offset_p = (p - 1) * S
        offset_q = (q - 1) * S
        for s in 1:S
            if iseven(p + s)
                push!(links, minmax(offset_p + s, offset_q + s))
            end
        end
    end

    links = unique(links)
    return TopologyOutput(links, Tuple{Int,Int}[], "Honeycomb")
end

# 解析公式：面内 P*S 条 + 面间约 P*S/2 条 ≈ T*3/2
function num_isl(::HoneycombStrategy, T::Int, P::Int)::Int
    S = div(T, P)
    intra = P * S
    inter = div(P * S + 1, 2)  # 偶节点约一半，向上取整保上界
    return intra + inter
end

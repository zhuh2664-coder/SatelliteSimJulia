# 环形拓扑。每颗卫星仅 2 条面内 ISL（前后邻居），无面间连接。
# 极简基线，用于对比。

export RingStrategy

struct RingStrategy <: AbstractTopologyStrategy end

function generate_topology(::RingStrategy, T::Int, P::Int)::TopologyOutput
    S = div(T, P)
    links = Tuple{Int,Int}[]

    # 每个平面 ring，无面间
    for p in 1:P
        offset = (p - 1) * S
        for (i, j) in generate_intra_plane_links(S)
            push!(links, (i + offset, j + offset))
        end
    end

    links = unique(links)
    return TopologyOutput(links, Tuple{Int,Int}[], "Ring")
end

# 解析公式：每平面 S 条 ring 边，共 P*S = T 条
function num_isl(::RingStrategy, T::Int, P::Int)::Int
    return T
end

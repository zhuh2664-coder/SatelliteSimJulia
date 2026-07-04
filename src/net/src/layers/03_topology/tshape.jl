# T 型拓扑。每颗卫星 3 条静态 ISL（2 面内 + 1 交替面间）+ 1 条动态 ISL。
# MOST 骨干拓扑。

export TShapeStrategy, generate_t_shape_static_links, generate_t_shape_dynamic_candidates

struct TShapeStrategy <: AbstractTopologyStrategy end

function generate_t_shape_static_links(T::Int, P::Int)::Vector{Tuple{Int,Int}}
    S = div(T, P)
    all_static = Tuple{Int,Int}[]
    for p in 1:P
        offset = (p - 1) * S
        for s in 1:S
            s_next = s % S + 1
            push!(all_static, minmax(offset + s, offset + s_next))
        end
    end
    for p in 1:2:(P-1)
        offset_p = (p - 1) * S
        for s in 1:S
            if isodd(s)
                q = p + 1
            else
                q = p == 1 ? P : p - 1
            end
            offset_q = (q - 1) * S
            push!(all_static, minmax(offset_p + s, offset_q + s))
        end
    end
    return unique(all_static)
end

function generate_t_shape_dynamic_candidates(T::Int, P::Int)::Vector{Tuple{Int,Int}}
    S = div(T, P)
    return generate_inter_plane_links(S, P, InterPlaneConfig(span=2, slot_offset=1))
end

function generate_topology(::TShapeStrategy, T::Int, P::Int)::TopologyOutput
    static = generate_t_shape_static_links(T, P)
    dynamic = generate_t_shape_dynamic_candidates(T, P)
    return TopologyOutput(static, dynamic, "T-Shape")
end

# 完全图（Mesh）拓扑。所有卫星两两互联。
# 仅用于小星座上界参考，大规模不可用。

export MeshStrategy

struct MeshStrategy <: AbstractTopologyStrategy end

function generate_topology(::MeshStrategy, T::Int, P::Int)::TopologyOutput
    links = Tuple{Int,Int}[]
    for i in 1:T, j in (i + 1):T
        push!(links, minmax(i, j))
    end
    links = unique(links)
    return TopologyOutput(links, Tuple{Int,Int}[], "Mesh")
end

# 解析公式：T*(T-1)/2 条边（完全图）
function num_isl(::MeshStrategy, T::Int, P::Int)::Int
    return T * (T - 1) ÷ 2
end

# 动态最近邻拓扑。每颗卫星连接距离最近的 k 颗卫星。
# 位置数据内嵌在策略 struct 里（多重分派：配置随类型走，不改方法签名）。

export NearestNeighborStrategy

Base.@kwdef struct NearestNeighborStrategy{A<:AbstractArray{<:Real,3}} <: AbstractTopologyStrategy
    positions::A                 # (N×T×3) 位置数组，允许 view/SubArray
    k::Int = 4                    # 每星连接数
    time_step::Int = 1            # 用 positions[:, time_step, :] 算距离
end

function generate_topology(strategy::NearestNeighborStrategy, T::Int, P::Int)::TopologyOutput
    N = size(strategy.positions, 1)
    1 <= strategy.time_step <= size(strategy.positions, 2) ||
        throw(ArgumentError("time_step must be in 1:$(size(strategy.positions, 2))"))
    strategy.k >= 0 || throw(ArgumentError("k must be non-negative"))
    pos = @view strategy.positions[:, strategy.time_step, :]  # N×3

    links = Set{Tuple{Int,Int}}()
    for i in 1:N
        # 计算卫星 i 到所有其他卫星 j 的欧氏距离
        dists = Tuple{Float64,Int}[]
        for j in 1:N
            i == j && continue
            d = sqrt(sum((pos[i, m] - pos[j, m])^2 for m in 1:size(pos, 2)))
            push!(dists, (d, j))
        end
        # 取最近的 k 个
        sort!(dists)
        kk = min(strategy.k, length(dists))
        for n in 1:kk
            j = dists[n][2]
            push!(links, minmax(i, j))
        end
    end

    dynamic = collect(links)
    return TopologyOutput(Tuple{Int,Int}[], dynamic, "NearestNeighbor(k=$(strategy.k))")
end

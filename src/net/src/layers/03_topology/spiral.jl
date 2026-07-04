# Spiral（螺旋/−Grid）拓扑。每颗卫星 4 条 ISL（2 面内 + 2 面间）。
# 面间连接带 slot 偏移，拓扑沿球面螺旋。Grid+ 的变体。

export SpiralStrategy

Base.@kwdef struct SpiralStrategy <: AbstractTopologyStrategy
    shift::Int = 1  # 面间 slot 偏移；0 退化为 Grid+
end

function generate_topology(strategy::SpiralStrategy, T::Int, P::Int)::TopologyOutput
    links = generate_isl_candidates(T, P; inter=InterPlaneConfig(slot_offset=strategy.shift))
    return TopologyOutput(links, Tuple{Int,Int}[], "Spiral")
end

# Spiral 总是 2T 条边（与 Grid+ 同构，仅面间偏移不同）
function num_isl(::SpiralStrategy, T::Int, P::Int)::Int
    return T * 2
end

"""
    GlobalRouting — 全局路由

对标 ns-3 Ipv4GlobalRoutingHelper。
基于 Floyd-Warshall / Dijkstra 计算全对最短路径。
适用于星座的全网路由表预计算。
"""
mutable struct GlobalRouting <: Ipv4RoutingProtocol
    entries::Dict{Tuple{Ipv4Address, Ipv4Address}, Tuple{Ipv4Address, Int}}  # (src, dst) → (next_hop, iface)
end

GlobalRouting() = GlobalRouting(Dict{Tuple{Ipv4Address, Ipv4Address}, Tuple{Ipv4Address, Int}}())

function AddRoute(r::GlobalRouting, src::Ipv4Address, dst::Ipv4Address,
                   next_hop::Ipv4Address, iface::Int)
    r.entries[(src, dst)] = (next_hop, iface)
    nothing
end

"""
    BuildFromPositions — 从 pos 矩阵构建路由

直接对接你的平台的 N×T×3 矩阵。
"""
function BuildFromPositions(pos::AbstractArray{Float64}, t::Int, nodes::Vector{UInt32})
    n = length(nodes)
    # 构建距离矩阵
    dist = fill(Inf, n, n)
    for i in 1:n, j in (i+1):n
        d = sqrt(sum((pos[i, t, :] - pos[j, t, :]).^2))  # 你这个是 N×T×3
        if d < 5000  # ISL 最大距离
            dist[i, j] = d
            dist[j, i] = d
        end
    end
    # Floyd-Warshall
    for k in 1:n, i in 1:n, j in 1:n
        if dist[i, k] + dist[k, j] < dist[i, j]
            dist[i, j] = dist[i, k] + dist[k, j]
        end
    end
    return dist
end

function RouteOutput(r::GlobalRouting, src::Ipv4Address, dst::Ipv4Address, pkt)
    return get(r.entries, (src, dst), nothing)
end

function RouteInput(r::GlobalRouting, pkt, iface, cb)
    return false
end

NotifyInterfaceUp(r::GlobalRouting, iface) = nothing
NotifyInterfaceDown(r::GlobalRouting, iface) = nothing

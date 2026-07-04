"""
    StaticRouting — 静态路由

对标 ns-3 Ipv4StaticRouting。
手动添加的路由表，优先级最高。
"""
mutable struct StaticRoute
    dst::Ipv4Address
    mask::Ipv4Mask
    next_hop::Ipv4Address
    interface::Int
    metric::Int
end

mutable struct StaticRouting <: Ipv4RoutingProtocol
    routes::Vector{StaticRoute}
end

StaticRouting() = StaticRouting(StaticRoute[])

function AddRoute(r::StaticRouting, dst::Ipv4Address, mask::Ipv4Mask,
                   next_hop::Ipv4Address, iface::Int; metric=0)
    push!(r.routes, StaticRoute(dst, mask, next_hop, iface, metric))
    nothing
end

function RemoveRoute(r::StaticRouting, dst::Ipv4Address, mask::Ipv4Mask)
    filter!(rt -> !(rt.dst == dst && rt.mask == mask), r.routes)
    nothing
end

"""
    RouteOutput(r, src, dst, pkt) → (next_hop, iface) | nothing
"""
function RouteOutput(r::StaticRouting, src::Ipv4Address, dst::Ipv4Address, pkt)
    # 最长前缀匹配
    best = nothing
    best_len = -1
    for route in r.routes
        masked = route.mask(dst)
        if masked == route.mask(route.dst)
            # 计算前缀长度
            len = count_ones(route.mask.mask)
            if len > best_len
                best = (route.next_hop, route.interface)
                best_len = len
            end
        end
    end
    return best
end

function RouteInput(r::StaticRouting, pkt, iface, cb)
    return false  # 静态路由不处理入站包转发
end

NotifyInterfaceUp(r::StaticRouting, iface) = nothing
NotifyInterfaceDown(r::StaticRouting, iface) = nothing

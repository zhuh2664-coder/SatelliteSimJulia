"""
    Ipv4RoutingProtocol — 路由协议抽象基类

对标 ns-3 Ipv4RoutingProtocol。
"""
abstract type Ipv4RoutingProtocol end

"""
    RouteOutput(proto, src, dst, pkt) → next_hop | nothing
为发往 dst 的包找到下一跳。
"""
function RouteOutput end

"""
    RouteInput(proto, pkt, interface, cb) → Bool
处理收到的包，可能转发或交付上层。
"""
function RouteInput end

"""
    NotifyInterfaceUp(proto, iface)
接口状态变化通知。
"""
function NotifyInterfaceUp end

"""
    NotifyInterfaceDown(proto, iface)
"""
function NotifyInterfaceDown end

"""
    AddRoute(proto, dst, mask, next_hop, iface)
添加路由条目。
"""
function AddRoute end

"""
    RemoveRoute(proto, dst, mask)
"""
function RemoveRoute end

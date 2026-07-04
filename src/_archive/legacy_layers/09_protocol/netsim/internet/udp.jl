"""
    UDP — 用户数据报协议

对标 ns-3 UdpSocket / UdpL4Protocol。
"""
const UDP_HEADER_SIZE = 8

mutable struct UdpHeader
    src_port::UInt16
    dst_port::UInt16
    length::UInt16
    checksum::UInt16
end

UdpHeader(src_port, dst_port, len) =
    UdpHeader(src_port, dst_port, len, 0)

"""
    UdpSocket — UDP 套接字

对标 ns-3 UdpSocket。
每端使用一个 socket，绑定端口，收发数据。
"""
mutable struct UdpSocket
    node::UInt32
    src_addr::Ipv4Address
    src_port::UInt16
    dst_addr::Ipv4Address
    dst_port::UInt16
    rx_callback::Union{Function, Nothing}  # 收到包时回调
    is_bound::Bool
    is_connected::Bool
end

UdpSocket(node::UInt32) = UdpSocket(node, Ipv4Address(), 0, Ipv4Address(), 0, nothing, false, false)

"""
    Bind(sock, addr, port)
"""
function Bind(sock::UdpSocket, addr::Ipv4Address, port::UInt16)
    sock.src_addr = addr
    sock.src_port = port
    sock.is_bound = true
    nothing
end

Bind(sock::UdpSocket, port::UInt16) = Bind(sock, Ipv4Address(), port)

"""
    Connect(sock, addr, port)
"""
function Connect(sock::UdpSocket, addr::Ipv4Address, port::UInt16)
    sock.dst_addr = addr
    sock.dst_port = port
    sock.is_connected = true
    nothing
end

"""
    Send(sock, data, size) → Bool
"""
function Send(sock::UdpSocket, data::Vector{UInt8}, size::Int)
    pkt = CreatePacket(UDP_HEADER_SIZE + size, sock.src_addr.addr, sock.dst_addr.addr; protocol=17)
    pkt.payload = data
    # 通过节点的第一个设备发送
    # 简化：这里假设节点有设备，实际应通过协议栈路由
    return true
end

"""
    SetRecvCallback(sock, cb)
"""
function SetRecvCallback(sock::UdpSocket, cb::Function)
    sock.rx_callback = cb
    nothing
end

"""
    Receive(sock, pkt)
"""
function Receive(sock::UdpSocket, pkt)
    if sock.rx_callback !== nothing
        sock.rx_callback(sock, pkt)
    end
    nothing
end

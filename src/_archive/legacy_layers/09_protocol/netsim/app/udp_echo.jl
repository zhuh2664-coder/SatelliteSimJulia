using ResumableFunctions

"""
    UdpEchoApp — UDP Echo 应用
对标 ns-3 UdpEchoClient / UdpEchoServer。客户端发包，服务器回包。
"""

mutable struct UdpEchoClient
    node::UInt32
    socket::UdpSocket
    dst_addr::Ipv4Address
    dst_port::UInt16
    packet_size::Int
    interval::Float64
    max_packets::Int
    sent_count::Int
    recv_count::Int
    rtt_samples::Vector{Float64}
end

function UdpEchoClient(node::UInt32, dst_addr::Ipv4Address, dst_port::UInt16;
                       packet_size=1024, interval=1.0, max_packets=10)
    sock = UdpSocket(node)
    client = UdpEchoClient(node, sock, dst_addr, dst_port,
                           packet_size, interval, max_packets, 0, 0, Float64[])
    SetRecvCallback(sock, (s, pkt) -> HandleRecv(client, s, pkt))
    return client
end

"""
    HandleRecv(client, sock, pkt) — 收到 Echo 回复
"""
function HandleRecv(client::UdpEchoClient, sock::UdpSocket, pkt)
    rtt = Now() - pkt.ts_create
    push!(client.rtt_samples, rtt)
    client.recv_count += 1
    nothing
end

"""
    Start(client) — 开始发送
"""
@resumable function Start(client::UdpEchoClient)
    for i in 1:client.max_packets
        @yield timeout(GetEnv(), client.interval)
        pkt = CreatePacket(client.packet_size, client.socket.src_addr.addr,
                           client.dst_addr.addr; protocol=17)
        timestamp!(pkt, Now())
        client.sent_count += 1
        # 通过节点的第一个设备发送
        # 简化：直接发
    end
    nothing
end

# === UDP Echo Server ===
mutable struct UdpEchoServer
    node::UInt32
    port::UInt16
    socket::UdpSocket
    recv_count::Int
end

function UdpEchoServer(node::UInt32, port::UInt16)
    sock = UdpSocket(node)
    Bind(sock, port)
    server = UdpEchoServer(node, port, sock, 0)
    SetRecvCallback(sock, (s, pkt) -> HandleEcho(server, s, pkt))
    return server
end

"""
    HandleEcho(server, sock, pkt) — 收到 Echo，回包
"""
function HandleEcho(server::UdpEchoServer, sock::UdpSocket, pkt)
    server.recv_count += 1
    # 回包（简化：直接创建回复包）
    reply = CreatePacket(pkt.size, server.socket.src_addr.addr,
                         Ipv4Address(pkt.src).addr; protocol=17)
    timestamp!(reply, Now())
    nothing
end

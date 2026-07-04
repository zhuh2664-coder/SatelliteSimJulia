"""
    PacketSinkApp — 包接收器

对标 ns-3 PacketSinkApplication。
统计收到的包数和字节数。
"""
mutable struct PacketSinkApp
    node::UInt32
    port::UInt16
    socket::UdpSocket
    recv_count::Int
    byte_count::Int
    first_recv::Float64
    last_recv::Float64
end

function PacketSinkApp(node::UInt32, port::UInt16)
    sock = UdpSocket(node)
    Bind(sock, port)
    sink = PacketSinkApp(node, port, sock, 0, 0, Inf, 0.0)
    SetRecvCallback(sock, (s, pkt) -> HandleRecv(sink, pkt))
    return sink
end

"""
    HandleRecv(sink, pkt) — 收到包
"""
function HandleRecv(sink::PacketSinkApp, pkt)
    if sink.recv_count == 0
        sink.first_recv = Now()
    end
    sink.recv_count += 1
    sink.byte_count += pkt.size
    sink.last_recv = Now()
    nothing
end

"""
    Throughput(sink) → bps
"""
function Throughput(sink::PacketSinkApp)
    if sink.recv_count < 2
        return 0.0
    end
    duration = sink.last_recv - sink.first_recv
    if duration <= 0
        return 0.0
    end
    return sink.byte_count * 8.0 / duration
end

"""
    AvgPacketRate(sink) → packets/s
"""
AvgPacketRate(sink::PacketSinkApp) = sink.recv_count / max(sink.last_recv - sink.first_recv, 1e-9)

"""
    BulkSendApp — 批量发送应用

对标 ns-3 BulkSendApplication。
持续发送数据（模拟大文件传输）。
"""
mutable struct BulkSendApp
    node::UInt32
    socket::UdpSocket
    dst_addr::Ipv4Address
    dst_port::UInt16
    packet_size::Int
    data_rate::Float64
    max_bytes::Int
    total_sent::Int
end

function BulkSendApp(node::UInt32, dst_addr::Ipv4Address, dst_port::UInt16;
                     packet_size=1460, data_rate=10e6, max_bytes=1_000_000_000)
    sock = UdpSocket(node)
    BulkSendApp(node, sock, dst_addr, dst_port, packet_size, data_rate, max_bytes, 0)
end

"""
    Start(app) — 开始批量发送
"""
@resumable function Start(app::BulkSendApp)
    interval = app.packet_size * 8.0 / app.data_rate
    while app.total_sent < app.max_bytes
        pkt = CreatePacket(app.packet_size, app.socket.src_addr.addr,
                           app.dst_addr.addr; protocol=17)
        app.total_sent += app.packet_size
        @yield timeout(GetEnv(), interval)
        if app.total_sent >= app.max_bytes
            break
        end
    end
    nothing
end

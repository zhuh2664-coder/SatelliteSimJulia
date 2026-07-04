"""
    OnOffApp — On/Off 流量

对标 ns-3 OnOffApplication。
交替在 On 状态（发包）和 Off 状态（不发）切换。
模拟突发流量。
"""
mutable struct OnOffApp
    node::UInt32
    socket::UdpSocket
    dst_addr::Ipv4Address
    dst_port::UInt16
    packet_size::Int
    data_rate::Float64     # bits/s
    on_time::Float64       # On 状态时长（秒）
    off_time::Float64      # Off 状态时长（秒）
    on_dist::Any           # On 时长分布
    off_dist::Any          # Off 时长分布
    total_sent::Int
    is_on::Bool
end

function OnOffApp(node::UInt32, dst_addr::Ipv4Address, dst_port::UInt16;
                  packet_size=1024, data_rate=1e6,
                  on_time=1.0, off_time=1.0)
    sock = UdpSocket(node)
    OnOffApp(node, sock, dst_addr, dst_port, packet_size, data_rate,
             on_time, off_time, ExponentialRandom(on_time),
             ExponentialRandom(off_time), 0, false)
end

"""
    Start(app) — 开始 On/Off 循环
"""
@resumable function Start(app::OnOffApp)
    while true
        # On 阶段：发包
        @yield timeout(GetEnv(), app.on_time)
        app.is_on = true
        interval = app.packet_size * 8.0 / app.data_rate
        on_end = Now() + app.on_time
        while Now() < on_end
            pkt = CreatePacket(app.packet_size, app.socket.src_addr.addr,
                               app.dst_addr.addr; protocol=17)
            app.total_sent += 1
            @yield timeout(GetEnv(), interval)
        end
        app.is_on = false

        # Off 阶段：不发
        @yield timeout(GetEnv(), app.off_time)
    end
end

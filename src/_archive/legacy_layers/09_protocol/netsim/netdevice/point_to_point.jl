using ConcurrentSim
using ResumableFunctions

"""
    PointToPointDevice — 点对点网卡
对标 ns-3 PointToPointNetDevice。用 ConcurrentSim 协程实现异步传输。
"""

mutable struct PointToPointDevice <: NetDevice
    node::UInt32               # 所属节点 ID
    channel::PointToPointChannel
    queue::Queue              # 发送队列
    mtu::Int
    rx_callback::Union{Function, Nothing}
    is_up::Bool

    # 发送/接收协程句柄（用于 @process）
    _send_process::Any
    _env::Simulation
end

"""
    PointToPointDevice(node_id, channel, env[; mtu, queue])
"""
function PointToPointDevice(node_id::UInt32, channel::PointToPointChannel,
                            env::Simulation; mtu=1500, queue=DropTailQueue())
    PointToPointDevice(node_id, channel, queue, mtu, nothing, true,
                       nothing, env)
end

GetNode(dev::PointToPointDevice) = dev.node
GetChannel(dev::PointToPointDevice) = dev.channel
GetQueue(dev::PointToPointDevice) = dev.queue
SetRecvCallback(dev::PointToPointDevice, cb::Function) = (dev.rx_callback = cb)
IsLinkUp(dev::PointToPointDevice) = dev.is_up

function SetQueue(dev::PointToPointDevice, q::Queue)
    dev.queue = q
    nothing
end

"""
    Send(dev, pkt, dst)
将包放入发送队列。dsr 在此未使用（P2P 只有一个对端）。
"""
function Send(dev::PointToPointDevice, pkt, dst=nothing)
    if !Enqueue(dev.queue, pkt)
        return false  # 队列满，丢包
    end
    # 如果发送协程没在跑，启动它
    if dev._send_process === nothing
        dev._send_process = @process _send_task(dev._env, dev)
    end
    return true
end

"""
    _send_task(env, dev)
发送协程：不断从队列取包 → 通过信道传输 → 等待传输完成 → 接收端入站。
"""
@resumable function _send_task(env::Simulation, dev::PointToPointDevice)
    while true
        pkt = Dequeue(dev.queue)
        if pkt === nothing
            # 队列空，等待新包入队
            @yield timeout(env, 0.001)  # 短暂等待
            continue
        end

        # 确定发送端索引（检查这个 device 在 channel 的哪一端）
        ch = dev.channel
        tx_idx = 1  # 假设我们是端1
        if GetNDevices(ch) >= 2 && GetDevice(ch, 2) === dev
            tx_idx = 2
        end

        # 通过信道传输
        rx_device, tx_time = Transmit(ch, pkt, tx_idx)

        # 等待传输完成（包大小/数据率）
        @yield timeout(env, tx_time)

        # 等待传播延迟
        @yield timeout(env, ch.delay)

        # 接收端处理
        Receive(rx_device, pkt, dev)

        # 更新到达时间
        pkt.ts_arrival = Now()
    end
end

"""
    Receive(dev, pkt, sender_dev)
接收包。如果有 rx_callback 就调用，否则直接返回。
"""
function Receive(dev::PointToPointDevice, pkt, sender_dev)
    if dev.rx_callback !== nothing
        dev.rx_callback(dev, pkt, sender_dev)
    end
    nothing
end

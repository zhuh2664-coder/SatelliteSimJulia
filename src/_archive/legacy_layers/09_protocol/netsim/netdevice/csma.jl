"""
    CsmaDevice — 总线型网卡

对标 ns-3 CsmaNetDevice。
CSMA/CD 总线接入。
"""
mutable struct CsmaDevice <: NetDevice
    node::UInt32
    channel::CsmaChannel
    queue::Queue
    mtu::Int
    rx_callback::Union{Function, Nothing}
    is_up::Bool
end

CsmaDevice(node::UInt32, channel::CsmaChannel; mtu=1500) =
    CsmaDevice(node, channel, DropTailQueue(), mtu, nothing, true)

GetNode(dev::CsmaDevice) = dev.node
GetChannel(dev::CsmaDevice) = dev.channel
GetQueue(dev::CsmaDevice) = dev.queue
SetRecvCallback(dev::CsmaDevice, cb) = (dev.rx_callback = cb)
IsLinkUp(dev::CsmaDevice) = dev.is_up
SetQueue(dev::CsmaDevice, q) = (dev.queue = q)

function Send(dev::CsmaDevice, pkt, dst=nothing)
    # 简单实现：入队 → 立即广播到所有设备
    if !Enqueue(dev.queue, pkt)
        return false
    end

    ch = dev.channel
    _, tx_time = Transmit(ch, pkt, 1)

    # 模拟传输延迟
    Schedule(tx_time) do
        for (i, other) in enumerate(ch.devices)
            if other !== dev
                pkt_copy = clone(pkt)
                Receive(other, pkt_copy, dev)
            end
        end
    end
    return true
end

function Receive(dev::CsmaDevice, pkt, sender_dev)
    if dev.rx_callback !== nothing
        dev.rx_callback(dev, pkt, sender_dev)
    end
    nothing
end

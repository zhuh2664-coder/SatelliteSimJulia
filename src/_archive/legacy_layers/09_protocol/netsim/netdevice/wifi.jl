"""
    WifiDevice — 无线网卡（占位）

对标 ns-3 WifiNetDevice。
完整 802.11 MAC/PHY 待后续实现。
当前为框架占位。
"""
mutable struct WifiDevice <: NetDevice
    node::UInt32
    channel::Nothing
    rx_callback::Union{Function, Nothing}
    is_up::Bool
end

WifiDevice(node::UInt32) = WifiDevice(node, nothing, nothing, true)
GetNode(dev::WifiDevice) = dev.node
GetChannel(dev::WifiDevice) = dev.channel
SetRecvCallback(dev::WifiDevice, cb) = (dev.rx_callback = cb)
IsLinkUp(dev::WifiDevice) = dev.is_up

function Send(dev::WifiDevice, pkt, dst=nothing)
    error("WifiDevice: not yet implemented")
end

function Receive(dev::WifiDevice, pkt, sender_dev)
    if dev.rx_callback !== nothing
        dev.rx_callback(dev, pkt, sender_dev)
    end
end

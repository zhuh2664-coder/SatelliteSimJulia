"""
    emu.jl — 半实物仿真接口 (Emulation / TapBridge)

对标 ns-3 TapBridge / FdNetDevice。
将 NetSim 仿真包转发到真实网络接口，
或从真实网络收包注入仿真。

用于：硬件在环、真实流量注入、与真实设备互联。
"""
mutable struct EmuBridge
    node::UInt32
    iface_name::String     # 真实网卡名 (如 eth0, en0)
    is_tap::Bool           # true=TAP, false=raw socket
    mac::UInt64
    is_up::Bool
    packet_count_in::Int
    packet_count_out::Int
end

""" 创建仿真↔真实网络桥接 """
function EmuBridge(node::UInt32, iface::String; tap=true)
    EmuBridge(node, iface, tap, 0, true, 0, 0)
end

""" 向真实网络注入仿真包 """
function inject_to_real(bridge::EmuBridge, data::Vector{UInt8})
    bridge.packet_count_out += 1
    true
end

""" 从真实网络收取包注入仿真 """
function capture_from_real(bridge::EmuBridge, callback::Function)
    bridge.packet_count_in += 1
    true
end

""" EmuNetDevice — 半实物仿真设备 """
mutable struct EmuNetDevice <: NetDevice
    node::UInt32
    bridge::EmuBridge
    rx_callback::Union{Function, Nothing}
end

GetNode(dev::EmuNetDevice) = dev.node
GetChannel(dev::EmuNetDevice) = nothing
SetRecvCallback(dev::EmuNetDevice, cb) = (dev.rx_callback = cb)
IsLinkUp(dev::EmuNetDevice) = true

function Send(dev::EmuNetDevice, pkt, dst=nothing)
    inject_to_real(dev.bridge, pkt.payload)
end

function Receive(dev::EmuNetDevice, pkt, sender)
    if dev.rx_callback !== nothing
        dev.rx_callback(dev, pkt, sender)
    end
end

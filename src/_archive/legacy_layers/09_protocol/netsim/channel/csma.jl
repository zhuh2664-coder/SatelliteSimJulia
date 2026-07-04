"""
    CsmaChannel — 总线型信道

对标 ns-3 CsmaChannel。
多设备共享的广播信道，CSMA/CD 风格。
"""
mutable struct CsmaChannel <: Channel
    devices::Vector{Any}
    delay::Float64
    data_rate::Float64
end

CsmaChannel(delay::Float64, data_rate::Float64) =
    CsmaChannel(Any[], delay, data_rate)

GetDelay(ch::CsmaChannel) = ch.delay
GetNDevices(ch::CsmaChannel) = length(ch.devices)
GetDevice(ch::CsmaChannel, i::Int) = ch.devices[i]

function Attach(ch::CsmaChannel, device)
    push!(ch.devices, device)
    nothing
end

function Transmit(ch::CsmaChannel, pkt, sender_idx::Int)
    tx_time = pkt.size * 8.0 / ch.data_rate
    return ch.devices, tx_time  # 广播给所有设备
end

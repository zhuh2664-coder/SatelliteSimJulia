using ConcurrentSim

"""
    PointToPointChannel — 点对点信道
对标 ns-3 PointToPointChannel。两端设备，固定传播延迟。内部用 ConcurrentSim DelayQueue。
"""

mutable struct PointToPointChannel <: Channel
    devices::Vector{Any}
    delay::Float64           # 传播延迟（秒）
    data_rate::Float64       # 比特率（bps）
    env::Simulation
    _queue::DelayQueue{Any}  # 带延迟的队列（自动等待 delay 秒）
end

"""
    PointToPointChannel(env, delay, data_rate)
构造器。delay = 传播延迟（秒），data_rate = 比特率（bps）
"""
function PointToPointChannel(env::Simulation, delay::Float64, data_rate::Float64)
    PointToPointChannel(Any[], delay, data_rate, env,
                        DelayQueue{Any}(env, delay))
end

GetDelay(ch::PointToPointChannel) = ch.delay
GetNDevices(ch::PointToPointChannel) = length(ch.devices)
GetDevice(ch::PointToPointChannel, i::Int) = ch.devices[i]

"""
    Attach(ch, device)
将设备连接到信道
"""
function Attach(ch::PointToPointChannel, device)
    push!(ch.devices, device)
    nothing
end

"""
    SetDelay(ch, delay)
动态更新传播延迟（用于卫星运动中 ISL 距离变化）
"""
function SetDelay(ch::PointToPointChannel, delay::Float64)
    ch.delay = delay
    # 重建 DelayQueue
    ch._queue = DelayQueue{Any}(ch.env, delay)
    nothing
end

"""
    Transmit(ch, pkt, sender_idx)
在信道上发送包。
sender_idx: 发送设备的索引 (1 或 2)
返回接收设备的索引。
"""
function Transmit(ch::PointToPointChannel, pkt, sender_idx::Int)
    # 计算传输延迟（包大小 / 数据率）
    tx_time = pkt.size * 8.0 / ch.data_rate  # 字节→比特

    # 找接收端
    rx_idx = sender_idx == 1 ? 2 : 1
    rx_device = ch.devices[rx_idx]

    # 记录时间戳
    pkt.ts_departure = Now()

    return rx_device, tx_time
end

"""
    GetDelayQueue(ch) → DelayQueue
用于 @yield take! 异步接收
"""
GetDelayQueue(ch::PointToPointChannel) = ch._queue

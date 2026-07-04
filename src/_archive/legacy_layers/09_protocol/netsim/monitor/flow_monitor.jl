"""
    FlowMonitor — 流统计分析

对标 ns-3 FlowMonitor。
自动统计每条流的：吞吐量、RTT、丢包率、抖动。
"""
mutable struct FlowStats
    src_addr::Ipv4Address
    dst_addr::Ipv4Address
    src_port::UInt16
    dst_port::UInt16
    protocol::UInt8

    tx_packets::Int
    tx_bytes::Int
    rx_packets::Int
    rx_bytes::Int
    lost_packets::Int

    delay_sum::Float64      # 累计延迟（秒）
    delay_sqr::Float64      # 延迟平方和（用于标准差）
    min_delay::Float64
    max_delay::Float64
    delay_count::Int

    jitter_sum::Float64
    last_delay::Float64

    time_first_tx::Float64
    time_last_rx::Float64
    time_first_rx::Float64
end

function FlowStats(src::Ipv4Address, dst::Ipv4Address,
                   src_port::UInt16, dst_port::UInt16, proto::UInt8)
    FlowStats(src, dst, src_port, dst_port, proto,
              0, 0, 0, 0, 0, 0.0, 0.0, Inf, 0.0, 0, 0.0, 0.0,
              Inf, 0.0, Inf)
end

mutable struct FlowMonitor
    flows::Dict{UInt64, FlowStats}  # 流 ID → 统计
    enable_rtt::Bool
    enable_jitter::Bool
end

FlowMonitor(;enable_rtt=true, enable_jitter=true) =
    FlowMonitor(Dict{UInt64, FlowStats}(), enable_rtt, enable_jitter)

"""
    FlowId(src, dst, src_port, dst_port, proto) → UInt64
生成流标识符。
"""
function FlowId(src::Ipv4Address, dst::Ipv4Address,
                src_port::UInt16, dst_port::UInt16, proto::UInt8)
    h = hash((src, dst, src_port, dst_port, proto))
    return UInt64(h)
end

"""
    RecordTx(mon, src, dst, src_port, dst_port, proto, size, time)
记录发送包
"""
function RecordTx(mon::FlowMonitor, src::Ipv4Address, dst::Ipv4Address,
                  src_port::UInt16, dst_port::UInt16, proto::UInt8,
                  size::Int, time::Float64)
    fid = FlowId(src, dst, src_port, dst_port, proto)
    if !haskey(mon.flows, fid)
        mon.flows[fid] = FlowStats(src, dst, src_port, dst_port, proto)
    end
    f = mon.flows[fid]
    f.tx_packets += 1
    f.tx_bytes += size
    if f.time_first_tx == Inf
        f.time_first_tx = time
    end
    nothing
end

"""
    RecordRx(mon, src, dst, src_port, dst_port, proto, size, time, delay)
记录接收包
"""
function RecordRx(mon::FlowMonitor, src::Ipv4Address, dst::Ipv4Address,
                  src_port::UInt16, dst_port::UInt16, proto::UInt8,
                  size::Int, time::Float64, delay::Float64)
    fid = FlowId(src, dst, src_port, dst_port, proto)
    if !haskey(mon.flows, fid)
        mon.flows[fid] = FlowStats(src, dst, src_port, dst_port, proto)
    end
    f = mon.flows[fid]
    f.rx_packets += 1
    f.rx_bytes += size
    f.time_last_rx = time
    if f.time_first_rx == Inf
        f.time_first_rx = time
    end

    # 延迟
    if mon.enable_rtt
        f.delay_sum += delay
        f.delay_sqr += delay * delay
        f.delay_count += 1
        f.min_delay = min(f.min_delay, delay)
        f.max_delay = max(f.max_delay, delay)
    end

    # 抖动
    if mon.enable_jitter && f.delay_count > 1
        f.jitter_sum += abs(delay - f.last_delay)
    end
    f.last_delay = delay
    nothing
end

"""
    RecordDrop(mon, src, dst, src_port, dst_port, proto)
记录丢包
"""
function RecordDrop(mon::FlowMonitor, src::Ipv4Address, dst::Ipv4Address,
                    src_port::UInt16, dst_port::UInt16, proto::UInt8)
    fid = FlowId(src, dst, src_port, dst_port, proto)
    if !haskey(mon.flows, fid)
        mon.flows[fid] = FlowStats(src, dst, src_port, dst_port, proto)
    end
    mon.flows[fid].lost_packets += 1
    nothing
end

"""
    GetFlowStats(mon) — 获取 FlowMonitor 结果
"""
GetFlowStats(mon::FlowMonitor) = mon.flows

"""
    PrintFlowStats(mon) — 格式化输出
"""
function PrintFlowStats(mon::FlowMonitor)
    for (fid, f) in mon.flows
        tx = f.tx_packets
        rx = f.rx_packets
        loss = tx > 0 ? (tx - rx) * 100.0 / tx : 0.0
        avg_delay = f.delay_count > 0 ? f.delay_sum / f.delay_count : 0.0
        avg_jitter = f.delay_count > 1 ? f.jitter_sum / (f.delay_count - 1) : 0.0

        duration = f.time_last_rx - f.time_first_tx
        throughput = duration > 0 ? f.rx_bytes * 8.0 / duration : 0.0

        println("流 [$f.src_addr:$(f.src_port) → $f.dst_addr:$(f.dst_port)]")
        println("  发送: $tx 包, 接收: $rx 包, 丢包率: $(round(loss, digits=1))%")
        println("  吞吐量: $(round(throughput/1e6, digits=2)) Mbps")
        println("  平均延迟: $(round(avg_delay*1000, digits=2)) ms")
        println("  最大延迟: $(round(f.max_delay*1000, digits=2)) ms")
        println("  最小延迟: $(round(f.min_delay*1000, digits=2)) ms")
        println("  平均抖动: $(round(avg_jitter*1000, digits=2)) ms")
        println()
    end
end

"""
    ToDataFrame(mon) → DataFrame
与你的平台对接：流转 DataFrame
"""
function ToDataFrame(mon::FlowMonitor)
    rows = []
    for (fid, f) in mon.flows
        tx = f.tx_packets
        rx = f.rx_packets
        loss = tx > 0 ? (tx - rx) * 100.0 / tx : 0.0
        avg_delay = f.delay_count > 0 ? f.delay_sum / f.delay_count : 0.0
        duration = f.time_last_rx - f.time_first_tx
        throughput = duration > 0 ? f.rx_bytes * 8.0 / duration : 0.0

        push!(rows, (src=string(f.src_addr), dst=string(f.dst_addr),
                     tx_packets=tx, rx_packets=rx, loss_pct=loss,
                     throughput_mbps=throughput/1e6,
                     avg_delay_ms=avg_delay*1000,
                     min_delay_ms=f.min_delay*1000,
                     max_delay_ms=f.max_delay*1000))
    end
    return rows
end

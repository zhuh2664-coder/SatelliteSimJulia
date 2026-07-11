# FlowMonitor — per-flow stats (ns-3 style, simplified)

export FlowKey, FlowStats, FlowMonitor
export record_tx!, record_rx!, record_drop!, flow_summary, print_flow_stats

"""5-tuple flow key (addresses as UInt32, no IPv4 type dependency)."""
struct FlowKey
    src::UInt32
    dst::UInt32
    src_port::UInt16
    dst_port::UInt16
    protocol::UInt8
end

mutable struct FlowStats
    key::FlowKey
    tx_packets::Int
    tx_bytes::Int
    rx_packets::Int
    rx_bytes::Int
    lost_packets::Int
    delay_sum::Float64
    delay_count::Int
    min_delay::Float64
    max_delay::Float64
    jitter_sum::Float64
    last_delay::Float64
    time_first_tx::Float64
    time_last_rx::Float64
end

function FlowStats(key::FlowKey)
    return FlowStats(key, 0, 0, 0, 0, 0, 0.0, 0, Inf, 0.0, 0.0, 0.0, Inf, 0.0)
end

mutable struct FlowMonitor
    flows::Dict{FlowKey,FlowStats}
    enable_jitter::Bool
end

FlowMonitor(; enable_jitter::Bool=true) = FlowMonitor(Dict{FlowKey,FlowStats}(), enable_jitter)

function _get!(mon::FlowMonitor, key::FlowKey)
    return get!(() -> FlowStats(key), mon.flows, key)
end

function record_tx!(
    mon::FlowMonitor,
    src::Integer,
    dst::Integer,
    src_port::Integer,
    dst_port::Integer,
    protocol::Integer,
    size::Int,
    time::Real,
)
    key = FlowKey(UInt32(src), UInt32(dst), UInt16(src_port), UInt16(dst_port), UInt8(protocol))
    f = _get!(mon, key)
    f.tx_packets += 1
    f.tx_bytes += size
    if f.time_first_tx == Inf
        f.time_first_tx = Float64(time)
    end
    return nothing
end

function record_rx!(
    mon::FlowMonitor,
    src::Integer,
    dst::Integer,
    src_port::Integer,
    dst_port::Integer,
    protocol::Integer,
    size::Int,
    time::Real,
    delay::Real,
)
    key = FlowKey(UInt32(src), UInt32(dst), UInt16(src_port), UInt16(dst_port), UInt8(protocol))
    f = _get!(mon, key)
    f.rx_packets += 1
    f.rx_bytes += size
    f.time_last_rx = Float64(time)
    d = Float64(delay)
    f.delay_sum += d
    f.delay_count += 1
    f.min_delay = min(f.min_delay, d)
    f.max_delay = max(f.max_delay, d)
    if mon.enable_jitter && f.delay_count > 1
        f.jitter_sum += abs(d - f.last_delay)
    end
    f.last_delay = d
    return nothing
end

function record_drop!(
    mon::FlowMonitor,
    src::Integer,
    dst::Integer,
    src_port::Integer,
    dst_port::Integer,
    protocol::Integer,
)
    key = FlowKey(UInt32(src), UInt32(dst), UInt16(src_port), UInt16(dst_port), UInt8(protocol))
    f = _get!(mon, key)
    f.lost_packets += 1
    return nothing
end

"""
    flow_summary(mon) -> Vector{NamedTuple}

Per-flow throughput / loss / delay / jitter summary.
"""
function flow_summary(mon::FlowMonitor)
    rows = NamedTuple[]
    for (_, f) in mon.flows
        tx, rx = f.tx_packets, f.rx_packets
        loss = tx > 0 ? (tx - rx) / tx : 0.0
        # also count explicit drops
        if f.lost_packets > 0 && tx > 0
            loss = max(loss, f.lost_packets / max(tx, f.lost_packets + rx))
        end
        avg_delay = f.delay_count > 0 ? f.delay_sum / f.delay_count : NaN
        avg_jitter = f.delay_count > 1 ? f.jitter_sum / (f.delay_count - 1) : 0.0
        dur = f.time_last_rx - f.time_first_tx
        thr = (dur > 0 && isfinite(dur)) ? f.rx_bytes * 8.0 / dur : 0.0
        push!(rows, (
            src=f.key.src,
            dst=f.key.dst,
            src_port=f.key.src_port,
            dst_port=f.key.dst_port,
            protocol=f.key.protocol,
            tx_packets=tx,
            rx_packets=rx,
            lost_packets=f.lost_packets,
            loss_ratio=loss,
            throughput_bps=thr,
            avg_delay_s=avg_delay,
            min_delay_s=isfinite(f.min_delay) ? f.min_delay : NaN,
            max_delay_s=f.max_delay,
            avg_jitter_s=avg_jitter,
        ))
    end
    return rows
end

function print_flow_stats(mon::FlowMonitor)
    for row in flow_summary(mon)
        @printf("flow %u:%u → %u:%u proto=%u\n",
                row.src, row.src_port, row.dst, row.dst_port, row.protocol)
        @printf("  tx/rx/lost: %d / %d / %d  loss=%.2f%%\n",
                row.tx_packets, row.rx_packets, row.lost_packets, 100 * row.loss_ratio)
        @printf("  throughput: %.3f Mbps\n", row.throughput_bps / 1e6)
        @printf("  delay: avg=%.3f ms  min=%.3f  max=%.3f  jitter=%.3f\n",
                1000 * row.avg_delay_s,
                1000 * (isnan(row.min_delay_s) ? 0.0 : row.min_delay_s),
                1000 * row.max_delay_s,
                1000 * row.avg_jitter_s)
    end
    return nothing
end

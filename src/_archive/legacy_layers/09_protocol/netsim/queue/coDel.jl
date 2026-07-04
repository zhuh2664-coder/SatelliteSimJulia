"""
    CoDelQueue — 控制延迟队列 (Controlled Delay)

对标 ns-3 CoDelQueue。
核心思想：监控每包在队列中的停留时间，
如果超过目标延迟（默认 5ms），则主动丢包。
消除"缓冲区膨胀"。
"""
mutable struct CoDelQueue <: Queue
    max_bytes::Int
    max_packets::Int
    _bytes::Int
    _packets::Int
    _queue::Vector{Any}
    drop_count::Int
    sojourn_count::Int

    # CoDel 参数
    target::Float64     # 目标延迟（秒），默认 5ms
    interval::Float64   # 检测间隔，默认 100ms

    # 内部状态
    dropping::Bool
    drop_next::Float64  # 下次丢包时间
    first_above_time::Float64  # 首次超过 target 的时间
    last_drop_time::Float64
end

function CoDelQueue(; max_packets=1000, max_bytes=1024*1024,
                     target=0.005, interval=0.1)
    CoDelQueue(max_bytes, max_packets, 0, 0, Any[], 0, 0,
               target, interval, false, 0.0, -Inf, -Inf)
end

function Enqueue(q::CoDelQueue, pkt)
    if q._packets >= q.max_packets || q._bytes + pkt.size > q.max_bytes
        Drop(q, pkt)
        q.drop_count += 1
        return false
    end

    # 记录入队时间
    pkt.ts_arrival = Now()
    push!(q._queue, pkt)
    q._packets += 1
    q._bytes += pkt.size
    return true
end

function Dequeue(q::CoDelQueue)
    isempty(q._queue) && return nothing

    now = Now()
    pkt = popfirst!(q._queue)
    q._packets -= 1
    q._bytes -= pkt.size

    # 计算在队列中的停留时间 (sojourn time)
    sojourn = now - pkt.ts_arrival

    if sojourn < q.target
        # 队列延迟正常 → 清除检测状态
        q.first_above_time = -Inf
    else
        # 超过目标延迟
        if q.first_above_time < 0
            q.first_above_time = now + q.interval
        elseif now >= q.first_above_time
            # 持续超时 → 开始丢包
            DropNext(q, now)
            return nothing  # 这个包丢了
        end
    end

    return pkt
end

function DropNext(q::CoDelQueue, now)
    # 丢包 + 计算下次丢包时间
    q.drop_count += 1
    q.dropping = true

    if isempty(q._queue)
        q.dropping = false
        return
    end

    pkt = popfirst!(q._queue)
    q._packets -= 1
    q._bytes -= pkt.size

    # CoDel 丢包间隔：interval / sqrt(count)
    q.sojourn_count += 1
    delta = q.interval / sqrt(q.sojourn_count)
    q.drop_next = now + delta
end

Peek(q::CoDelQueue) = isempty(q._queue) ? nothing : q._queue[1]
BytesInQueue(q::CoDelQueue) = q._bytes
PacketsInQueue(q::CoDelQueue) = q._packets

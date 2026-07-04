"""
    RedQueue — 随机早期检测队列

对标 ns-3 RedQueue。
在队列满之前随机丢包，避免全局同步。
"""
mutable struct RedQueue <: Queue
    max_bytes::Int
    max_packets::Int
    _bytes::Int
    _packets::Int
    _queue::Vector{Any}
    drop_count::Int

    # RED 参数
    min_th::Float64
    max_th::Float64
    max_p::Float64
    w_q::Float64          # 加权因子（指数平均）
    avg_queue::Float64     # 指数平均队列长度
    count::Int             # 上次丢包后入队的包数
end

function RedQueue(; max_packets=1000, max_bytes=1024*1024,
                   min_th=5.0, max_th=15.0,
                   max_p=0.02, w_q=0.002)
    return RedQueue(max_bytes, max_packets, 0, 0, Any[], 0,
                    min_th, max_th, max_p, w_q, 0.0, 0)
end

function Enqueue(q::RedQueue, pkt)
    # 更新指数平均队列长度
    q.avg_queue = (1 - q.w_q) * q.avg_queue + q.w_q * q._packets

    if q._packets >= q.max_packets || q._bytes + pkt.size > q.max_bytes
        Drop(q, pkt)
        q.drop_count += 1
        q.count = 0
        return false
    end

    if q.avg_queue >= q.min_th && q._packets > 1
        if q.avg_queue >= q.max_th
            Drop(q, pkt)
            q.drop_count += 1
            q.count = 0
            return false
        else
            # 线性计算丢包概率
            pb = q.max_p * (q.avg_queue - q.min_th) / (q.max_th - q.min_th)
            pa = pb / (1 - q.count * pb)
            if rand() < pa
                Drop(q, pkt)
                q.drop_count += 1
                q.count = 0
                return false
            end
        end
    end

    push!(q._queue, pkt)
    q._packets += 1
    q._bytes += pkt.size
    q.count += 1
    return true
end

function Dequeue(q::RedQueue)
    isempty(q._queue) && return nothing
    pkt = popfirst!(q._queue)
    q._packets -= 1
    q._bytes -= pkt.size
    return pkt
end

function Peek(q::RedQueue)
    isempty(q._queue) && return nothing
    return q._queue[1]
end

BytesInQueue(q::RedQueue) = q._bytes
PacketsInQueue(q::RedQueue) = q._packets

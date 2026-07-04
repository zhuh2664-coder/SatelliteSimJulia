"""
    DropTailQueue — 尾丢弃队列

对标 ns-3 DropTailQueue。
先到先出，满了就丢。
"""
mutable struct DropTailQueue <: Queue
    max_bytes::Int                # 最大字节数
    max_packets::Int              # 最大包数
    _bytes::Int                   # 当前字节数
    _packets::Int                 # 当前包数
    _queue::Vector{Any}           # FIFO 队列
    drop_count::Int               # 丢包计数
end

function DropTailQueue(; max_bytes=1024*1024, max_packets=1000)
    DropTailQueue(max_bytes, max_packets, 0, 0, Any[], 0)
end

function Enqueue(q::DropTailQueue, pkt)
    if q._packets >= q.max_packets || q._bytes + pkt.size > q.max_bytes
        Drop(q, pkt)
        q.drop_count += 1
        return false
    end
    push!(q._queue, pkt)
    q._packets += 1
    q._bytes += pkt.size
    return true
end

function Dequeue(q::DropTailQueue)
    isempty(q._queue) && return nothing
    pkt = popfirst!(q._queue)
    q._packets -= 1
    q._bytes -= pkt.size
    return pkt
end

function Peek(q::DropTailQueue)
    isempty(q._queue) && return nothing
    return q._queue[1]
end

BytesInQueue(q::DropTailQueue) = q._bytes
PacketsInQueue(q::DropTailQueue) = q._packets

function SetCapacity(q::DropTailQueue; max_bytes=nothing, max_packets=nothing)
    max_bytes !== nothing && (q.max_bytes = max_bytes)
    max_packets !== nothing && (q.max_packets = max_packets)
end

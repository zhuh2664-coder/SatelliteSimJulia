# DropTailQueue — FIFO with tail drop (ns-3 DropTailQueue)

export DropTailQueue

"""
    DropTailQueue(; max_packets=1000, max_bytes=1024*1024)

FIFO queue that drops arriving packets when full (by packet count or byte count).
"""
mutable struct DropTailQueue <: AbstractQueue
    max_bytes::Int
    max_packets::Int
    _bytes::Int
    _packets::Int
    _queue::Vector{Packet}
    drops::Int
end

function DropTailQueue(; max_bytes::Int=1024 * 1024, max_packets::Int=1000)
    max_bytes > 0 || throw(ArgumentError("max_bytes must be positive"))
    max_packets > 0 || throw(ArgumentError("max_packets must be positive"))
    return DropTailQueue(max_bytes, max_packets, 0, 0, Packet[], 0)
end

function enqueue!(q::DropTailQueue, pkt::Packet)
    if q._packets >= q.max_packets || q._bytes + pkt.size > q.max_bytes
        q.drops += 1
        return false
    end
    push!(q._queue, pkt)
    q._packets += 1
    q._bytes += pkt.size
    return true
end

function dequeue!(q::DropTailQueue)
    isempty(q._queue) && return nothing
    pkt = popfirst!(q._queue)
    q._packets -= 1
    q._bytes -= pkt.size
    return pkt
end

function peek(q::DropTailQueue)
    isempty(q._queue) && return nothing
    return q._queue[1]
end

bytes_in_queue(q::DropTailQueue) = q._bytes
packets_in_queue(q::DropTailQueue) = q._packets
drop_count(q::DropTailQueue) = q.drops

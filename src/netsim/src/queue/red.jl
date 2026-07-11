# RED — Random Early Detection (ns-3 style)

export RedQueue

"""
    RedQueue(; max_packets, max_bytes, min_th, max_th, max_p, w_q)

Random Early Detection: drop with rising probability as EWMA queue length
grows between `min_th` and `max_th` (in packets).
"""
mutable struct RedQueue <: AbstractQueue
    max_bytes::Int
    max_packets::Int
    _bytes::Int
    _packets::Int
    _queue::Vector{Packet}
    drops::Int
    min_th::Float64
    max_th::Float64
    max_p::Float64
    w_q::Float64
    avg_queue::Float64
    count::Int
end

function RedQueue(;
    max_bytes::Int=1024 * 1024,
    max_packets::Int=1000,
    min_th::Real=5.0,
    max_th::Real=15.0,
    max_p::Real=0.02,
    w_q::Real=0.002,
)
    max_bytes > 0 || throw(ArgumentError("max_bytes must be positive"))
    max_packets > 0 || throw(ArgumentError("max_packets must be positive"))
    0 < min_th < max_th || throw(ArgumentError("need 0 < min_th < max_th"))
    0 < max_p <= 1 || throw(ArgumentError("max_p must be in (0,1]"))
    0 < w_q <= 1 || throw(ArgumentError("w_q must be in (0,1]"))
    return RedQueue(
        max_bytes, max_packets, 0, 0, Packet[], 0,
        Float64(min_th), Float64(max_th), Float64(max_p), Float64(w_q), 0.0, 0,
    )
end

function enqueue!(q::RedQueue, pkt::Packet)
    q.avg_queue = (1 - q.w_q) * q.avg_queue + q.w_q * q._packets

    if q._packets >= q.max_packets || q._bytes + pkt.size > q.max_bytes
        q.drops += 1
        q.count = 0
        return false
    end

    if q.avg_queue >= q.min_th
        if q.avg_queue >= q.max_th
            q.drops += 1
            q.count = 0
            return false
        else
            pb = q.max_p * (q.avg_queue - q.min_th) / (q.max_th - q.min_th)
            denom = 1 - q.count * pb
            pa = denom > 0 ? pb / denom : 1.0
            if rand() < pa
                q.drops += 1
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

function dequeue!(q::RedQueue)
    isempty(q._queue) && return nothing
    pkt = popfirst!(q._queue)
    q._packets -= 1
    q._bytes -= pkt.size
    return pkt
end

function peek(q::RedQueue)
    isempty(q._queue) && return nothing
    return q._queue[1]
end

bytes_in_queue(q::RedQueue) = q._bytes
packets_in_queue(q::RedQueue) = q._packets
drop_count(q::RedQueue) = q.drops

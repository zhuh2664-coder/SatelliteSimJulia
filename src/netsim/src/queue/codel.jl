# CoDel — Controlled Delay AQM (ns-3 style, simplified)

export CoDelQueue, set_queue_time!

"""
    CoDelQueue(; max_packets, max_bytes, target, interval)

Controlled Delay: drop on dequeue when sojourn time stays above `target`
for longer than `interval`. Call `set_queue_time!(q, t)` before enqueue/dequeue
when used outside ConcurrentSim (tests), or let DES path set it from `now(env)`.
"""
mutable struct CoDelQueue <: AbstractQueue
    max_bytes::Int
    max_packets::Int
    _bytes::Int
    _packets::Int
    _queue::Vector{Packet}
    drops::Int
    target::Float64
    interval::Float64
    sim_time::Float64
    first_above_time::Float64
    count::Int
end

function CoDelQueue(;
    max_bytes::Int=1024 * 1024,
    max_packets::Int=1000,
    target::Real=0.005,
    interval::Real=0.1,
)
    max_bytes > 0 || throw(ArgumentError("max_bytes must be positive"))
    max_packets > 0 || throw(ArgumentError("max_packets must be positive"))
    target > 0 || throw(ArgumentError("target must be positive"))
    interval > 0 || throw(ArgumentError("interval must be positive"))
    return CoDelQueue(
        max_bytes, max_packets, 0, 0, Packet[], 0,
        Float64(target), Float64(interval), 0.0, -Inf, 0,
    )
end

set_queue_time!(q::CoDelQueue, t::Real) = (q.sim_time = Float64(t); q)

function enqueue!(q::CoDelQueue, pkt::Packet)
    if q._packets >= q.max_packets || q._bytes + pkt.size > q.max_bytes
        q.drops += 1
        return false
    end
    pkt.ts_arrival = q.sim_time
    push!(q._queue, pkt)
    q._packets += 1
    q._bytes += pkt.size
    return true
end

function dequeue!(q::CoDelQueue)
    isempty(q._queue) && return nothing
    now = q.sim_time
    pkt = popfirst!(q._queue)
    q._packets -= 1
    q._bytes -= pkt.size

    sojourn = now - pkt.ts_arrival
    if sojourn < q.target
        q.first_above_time = -Inf
        q.count = 0
        return pkt
    end

    # sojourn above target
    if q.first_above_time < 0
        q.first_above_time = now + q.interval
        return pkt
    elseif now < q.first_above_time
        return pkt
    else
        # sustained congestion → drop this packet
        q.drops += 1
        q.count += 1
        # schedule next control point sooner as count grows
        q.first_above_time = now + q.interval / sqrt(q.count)
        return nothing
    end
end

function peek(q::CoDelQueue)
    isempty(q._queue) && return nothing
    return q._queue[1]
end

bytes_in_queue(q::CoDelQueue) = q._bytes
packets_in_queue(q::CoDelQueue) = q._packets
drop_count(q::CoDelQueue) = q.drops

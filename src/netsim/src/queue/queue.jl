# Queue abstract interface (ns-3 style)

export AbstractQueue, enqueue!, dequeue!, peek, bytes_in_queue, packets_in_queue, drop_count

"""Abstract network queue."""
abstract type AbstractQueue end

"""Enqueue `pkt`. Return `true` on success, `false` if dropped."""
function enqueue! end

"""Dequeue head packet, or `nothing` if empty."""
function dequeue! end

"""Peek head packet without removing, or `nothing` if empty."""
function peek end

bytes_in_queue(q::AbstractQueue) = error("bytes_in_queue not implemented for $(typeof(q))")
packets_in_queue(q::AbstractQueue) = error("packets_in_queue not implemented for $(typeof(q))")
drop_count(q::AbstractQueue) = error("drop_count not implemented for $(typeof(q))")

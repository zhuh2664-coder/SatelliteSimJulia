# Packet — ns-3 style packet (simplified)

export Packet, create_packet!, reset_packet_counter!

"""
    Packet

Minimal packet for discrete-event satellite network simulation.
"""
mutable struct Packet
    id::UInt64
    size::Int
    src::UInt32
    dst::UInt32
    protocol::UInt8
    ts_create::Float64
    ts_arrival::Float64
    ts_departure::Float64
end

const _PKT_COUNTER = Ref{UInt64}(0)

"""Reset the global packet id counter (useful between runs / tests)."""
reset_packet_counter!() = (_PKT_COUNTER[] = 0; nothing)

"""
    create_packet!(size, src, dst; protocol=17) -> Packet

Allocate a new packet with a monotonically increasing id.
"""
function create_packet!(size::Int, src::UInt32, dst::UInt32; protocol::UInt8=UInt8(17))
    size > 0 || throw(ArgumentError("packet size must be positive"))
    _PKT_COUNTER[] += 1
    return Packet(_PKT_COUNTER[], size, src, dst, protocol, 0.0, 0.0, 0.0)
end

create_packet!(size::Int, src::Integer, dst::Integer; kwargs...) =
    create_packet!(size, UInt32(src), UInt32(dst); kwargs...)

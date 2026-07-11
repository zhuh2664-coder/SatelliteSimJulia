# Bridge helpers that consume analytical-layer hop delays.
# Kept in the netsim package but only used when callers already have
# per-hop delays from SatelliteSimNet / SatelliteSimLink.

export hops_from_prop_ms

"""
    hops_from_prop_ms(prop_delay_ms, data_rate_bps; max_packets=32) -> Vector{PathHop}

Build DES hops from analytical per-hop propagation delays (milliseconds).
"""
function hops_from_prop_ms(
    prop_delay_ms::AbstractVector{<:Real},
    data_rate_bps::Real;
    max_packets::Int=32,
)
    return [PathHop(d / 1000.0, data_rate_bps; max_packets=max_packets) for d in prop_delay_ms]
end

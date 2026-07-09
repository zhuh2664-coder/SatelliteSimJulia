# Packet-level DES over a multi-hop path with known per-hop propagation delays.
# This is the Phase-1 bridge: analytical topology/routing supplies the path;
# NetSim supplies queueing delay, drops, and latency distributions.

export PathHop, PathSimConfig, PathSimResult, simulate_path

"""
    PathHop(prop_delay_s, data_rate_bps; max_packets=32)

One hop on a path: propagation delay (seconds) and link rate (bps).
"""
struct PathHop
    prop_delay_s::Float64
    data_rate_bps::Float64
    max_packets::Int
end

function PathHop(prop_delay_s::Real, data_rate_bps::Real; max_packets::Int=32)
    prop_delay_s >= 0 || throw(ArgumentError("prop_delay_s must be non-negative"))
    data_rate_bps > 0 || throw(ArgumentError("data_rate_bps must be positive"))
    max_packets > 0 || throw(ArgumentError("max_packets must be positive"))
    return PathHop(Float64(prop_delay_s), Float64(data_rate_bps), max_packets)
end

"""
    PathSimConfig

Configuration for a single-flow multi-hop DES experiment.
"""
struct PathSimConfig
    hops::Vector{PathHop}
    pkt_bytes::Int
    load_bps::Float64
    duration_s::Float64
    poisson::Bool
    seed::Int
end

function PathSimConfig(
    hops::Vector{PathHop};
    pkt_bytes::Int=1500,
    load_bps::Real=90e6,
    duration_s::Real=2.0,
    poisson::Bool=true,
    seed::Int=42,
)
    isempty(hops) && throw(ArgumentError("hops must be non-empty"))
    pkt_bytes > 0 || throw(ArgumentError("pkt_bytes must be positive"))
    load_bps > 0 || throw(ArgumentError("load_bps must be positive"))
    duration_s > 0 || throw(ArgumentError("duration_s must be positive"))
    return PathSimConfig(hops, pkt_bytes, Float64(load_bps), Float64(duration_s), poisson, seed)
end

"""
    PathSimResult

Aggregate metrics from a path DES run.
"""
struct PathSimResult
    n_sent::Int
    n_delivered::Int
    n_dropped::Int
    drop_ratio::Float64
    prop_delay_ms::Float64
    mean_latency_ms::Float64
    p95_latency_ms::Float64
    max_latency_ms::Float64
    mean_queue_delay_ms::Float64
    hop_drops::Vector{Int}
    latency_samples_ms::Vector{Float64}
end

function _p95(xs::Vector{Float64})
    isempty(xs) && return NaN
    s = sort(xs)
    return s[max(1, ceil(Int, 0.95 * length(s)))]
end

# Mutable run state shared by ConcurrentSim processes.
# (@resumable must be at module scope — it expands to a struct.)
mutable struct _PathRunState
    queues::Vector{DropTailQueue}
    busy_until::Vector{Float64}
    services::Vector{Float64}
    prop_s::Vector{Float64}
    pkt_bytes::Int
    interarrival::Float64
    duration_s::Float64
    poisson::Bool
    lat_samples::Vector{Float64}
    n_sent::Int
    n_deliv::Int
    n_drop::Int
end

@resumable function _journey(env, st::_PathRunState, t_enter::Float64)
    nhops = length(st.queues)
    for h in 1:nhops
        pkt = create_packet!(st.pkt_bytes, UInt32(1), UInt32(2))
        if !enqueue!(st.queues[h], pkt)
            st.n_drop += 1
            return
        end
        start = max(ConcurrentSim.now(env), st.busy_until[h])
        st.busy_until[h] = start + st.services[h]
        wait = start - ConcurrentSim.now(env)
        @yield ConcurrentSim.timeout(env, wait + st.services[h])
        dequeue!(st.queues[h])
        @yield ConcurrentSim.timeout(env, st.prop_s[h])
    end
    st.n_deliv += 1
    push!(st.lat_samples, (ConcurrentSim.now(env) - t_enter) * 1000.0)
end

@resumable function _source(env, st::_PathRunState)
    while ConcurrentSim.now(env) < st.duration_s
        st.n_sent += 1
        @process _journey(env, st, ConcurrentSim.now(env))
        gap = st.poisson ? st.interarrival * randexp() : st.interarrival
        @yield ConcurrentSim.timeout(env, gap)
    end
end

"""
    simulate_path(cfg::PathSimConfig) -> PathSimResult

Run a packet-level discrete-event simulation over `cfg.hops`.

Each hop is a DropTail FIFO single-server queue. Arrivals are either
deterministic (CBR) or Poisson (`cfg.poisson=true`). Propagation delays
come from the analytical ISL layer; queueing delay and drops are DES-only.
"""
function simulate_path(cfg::PathSimConfig)::PathSimResult
    Random.seed!(cfg.seed)
    reset_packet_counter!()

    nhops = length(cfg.hops)
    interarrival = cfg.pkt_bytes * 8 / cfg.load_bps
    services = [cfg.pkt_bytes * 8 / h.data_rate_bps for h in cfg.hops]
    prop_s = [h.prop_delay_s for h in cfg.hops]
    prop_ms = sum(prop_s) * 1000.0
    tx_ms = sum(services) * 1000.0

    queues = [
        DropTailQueue(max_packets=h.max_packets, max_bytes=h.max_packets * cfg.pkt_bytes)
        for h in cfg.hops
    ]

    st = _PathRunState(
        queues,
        zeros(Float64, nhops),
        services,
        prop_s,
        cfg.pkt_bytes,
        interarrival,
        cfg.duration_s,
        cfg.poisson,
        Float64[],
        0,
        0,
        0,
    )

    env = ConcurrentSim.Simulation()
    @process _source(env, st)
    ConcurrentSim.run(env, cfg.duration_s + 1.0)

    mean_lat = isempty(st.lat_samples) ? NaN : mean(st.lat_samples)
    mean_q = isempty(st.lat_samples) ? NaN : mean_lat - prop_ms - tx_ms
    hop_drops = [drop_count(q) for q in queues]
    sent = st.n_sent
    dropped = st.n_drop

    return PathSimResult(
        sent,
        st.n_deliv,
        dropped,
        sent == 0 ? 0.0 : dropped / sent,
        prop_ms,
        mean_lat,
        _p95(st.lat_samples),
        isempty(st.lat_samples) ? NaN : maximum(st.lat_samples),
        mean_q,
        hop_drops,
        st.lat_samples,
    )
end

"""
    simulate_path(prop_delay_ms, data_rate_bps; kwargs...) -> PathSimResult

Convenience: build equal-rate hops from per-hop propagation delays in milliseconds.
"""
function simulate_path(
    prop_delay_ms::AbstractVector{<:Real},
    data_rate_bps::Real;
    max_packets::Int=32,
    kwargs...,
)
    hops = [PathHop(d / 1000.0, data_rate_bps; max_packets=max_packets) for d in prop_delay_ms]
    return simulate_path(PathSimConfig(hops; kwargs...))
end

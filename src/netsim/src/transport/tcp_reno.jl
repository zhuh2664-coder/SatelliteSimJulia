# Simplified TCP Reno over a multi-hop DES path (single flow)

export TcpRenoConfig, TcpRenoResult, simulate_tcp_reno

"""
    TcpRenoConfig

Single-flow TCP Reno over a fixed multi-hop path (same hop model as `simulate_path`).
"""
struct TcpRenoConfig
    hops::Vector{PathHop}
    mss_bytes::Int
    total_bytes::Int
    rto_s::Float64
    init_cwnd::Int
    ssthresh::Int
    seed::Int
end

function TcpRenoConfig(
    hops::Vector{PathHop};
    mss_bytes::Int=1460,
    total_bytes::Int=50_000,
    rto_s::Real=0.5,
    init_cwnd::Int=1,
    ssthresh::Int=32,
    seed::Int=1,
)
    isempty(hops) && throw(ArgumentError("hops must be non-empty"))
    mss_bytes > 0 || throw(ArgumentError("mss_bytes must be positive"))
    total_bytes > 0 || throw(ArgumentError("total_bytes must be positive"))
    return TcpRenoConfig(hops, mss_bytes, total_bytes, Float64(rto_s), init_cwnd, ssthresh, seed)
end

struct TcpRenoResult
    bytes_acked::Int
    segments_sent::Int
    retransmits::Int
    drops::Int
    duration_s::Float64
    goodput_bps::Float64
    final_cwnd::Int
    final_ssthresh::Int
    mean_rtt_s::Float64
    completed::Bool
end

mutable struct _TcpState
    queues::Vector{DropTailQueue}
    busy_until::Vector{Float64}
    services::Vector{Float64}
    prop_s::Vector{Float64}
    mss::Int
    total_bytes::Int
    rto_s::Float64
    cwnd::Float64
    ssthresh::Float64
    next_seq::Int
    una::Int
    send_time::Dict{Int,Float64}
    acked::Set{Int}
    bytes_acked::Int
    segments_sent::Int
    retransmits::Int
    drops::Int
    rtt_sum::Float64
    rtt_n::Int
    finished::Bool
    finish_time::Float64
end

@resumable function _tcp_deliver(env, st::_TcpState, seq::Int, size::Int)
    for h in 1:length(st.queues)
        pkt = create_packet!(size, UInt32(1), UInt32(2); protocol=UInt8(6))
        if !enqueue!(st.queues[h], pkt)
            st.drops += 1
            return
        end
        start = max(ConcurrentSim.now(env), st.busy_until[h])
        st.busy_until[h] = start + st.services[h]
        wait = start - ConcurrentSim.now(env)
        @yield ConcurrentSim.timeout(env, wait + st.services[h])
        dequeue!(st.queues[h])
        @yield ConcurrentSim.timeout(env, st.prop_s[h])
    end
    # reverse-path ACK delay ≈ same total propagation
    @yield ConcurrentSim.timeout(env, sum(st.prop_s))
    push!(st.acked, seq)
end

@resumable function _tcp_sender(env, st::_TcpState)
    while st.bytes_acked < st.total_bytes
        # fill window
        outstanding = count(seq -> !haskey(st.send_time, seq) || !(seq in st.acked),
                            st.una:st.mss:(st.next_seq - 1))
        # recount outstanding from send_time not yet acked
        outstanding = count(seq -> !(seq in st.acked), keys(st.send_time))
        while outstanding < floor(Int, st.cwnd) && st.next_seq < st.total_bytes
            seq = st.next_seq
            size = min(st.mss, st.total_bytes - seq)
            st.next_seq += size
            st.segments_sent += 1
            st.send_time[seq] = ConcurrentSim.now(env)
            @process _tcp_deliver(env, st, seq, size)
            outstanding += 1
        end

        t_wait_start = ConcurrentSim.now(env)
        got = false
        ack_seq = 0
        while ConcurrentSim.now(env) - t_wait_start < st.rto_s
            # check for any newly acked seq
            for seq in keys(st.send_time)
                if seq in st.acked
                    ack_seq = seq
                    got = true
                    break
                end
            end
            got && break
            @yield ConcurrentSim.timeout(env, 0.0005)
        end

        if got
            send_t = st.send_time[ack_seq]
            rtt = ConcurrentSim.now(env) - send_t
            st.rtt_sum += rtt
            st.rtt_n += 1
            delete!(st.send_time, ack_seq)
            delete!(st.acked, ack_seq)
            st.bytes_acked += min(st.mss, st.total_bytes - ack_seq)
            # advance una
            while st.una < st.next_seq && !(st.una in keys(st.send_time))
                st.una += st.mss
            end
            if st.cwnd < st.ssthresh
                st.cwnd += 1.0
            else
                st.cwnd += 1.0 / max(st.cwnd, 1.0)
            end
        else
            # RTO on oldest outstanding
            if !isempty(st.send_time)
                seq = minimum(keys(st.send_time))
                size = min(st.mss, st.total_bytes - seq)
                st.retransmits += 1
                st.segments_sent += 1
                st.ssthresh = max(floor(st.cwnd / 2), 2.0)
                st.cwnd = 1.0
                st.send_time[seq] = ConcurrentSim.now(env)
                @process _tcp_deliver(env, st, seq, size)
            end
        end
    end
    st.finish_time = ConcurrentSim.now(env)
    st.finished = true
end

"""
    simulate_tcp_reno(cfg) -> TcpRenoResult

Simplified TCP Reno: slow start / congestion avoidance, RTO on loss.
"""
function simulate_tcp_reno(cfg::TcpRenoConfig)::TcpRenoResult
    Random.seed!(cfg.seed)
    reset_packet_counter!()

    nhops = length(cfg.hops)
    services = [cfg.mss_bytes * 8 / h.data_rate_bps for h in cfg.hops]
    prop_s = [h.prop_delay_s for h in cfg.hops]
    queues = [
        DropTailQueue(max_packets=h.max_packets, max_bytes=h.max_packets * cfg.mss_bytes)
        for h in cfg.hops
    ]

    st = _TcpState(
        queues,
        zeros(Float64, nhops),
        services,
        prop_s,
        cfg.mss_bytes,
        cfg.total_bytes,
        cfg.rto_s,
        Float64(cfg.init_cwnd),
        Float64(cfg.ssthresh),
        0,
        0,
        Dict{Int,Float64}(),
        Set{Int}(),
        0,
        0,
        0,
        0,
        0.0,
        0,
        false,
        NaN,
    )

    env = ConcurrentSim.Simulation()
    @process _tcp_sender(env, st)
    ConcurrentSim.run(env, 120.0)

    dur = isnan(st.finish_time) ? ConcurrentSim.now(env) : st.finish_time
    goodput = dur > 0 ? st.bytes_acked * 8.0 / dur : 0.0
    mean_rtt = st.rtt_n > 0 ? st.rtt_sum / st.rtt_n : NaN
    return TcpRenoResult(
        st.bytes_acked,
        st.segments_sent,
        st.retransmits,
        st.drops,
        dur,
        goodput,
        floor(Int, st.cwnd),
        floor(Int, st.ssthresh),
        mean_rtt,
        st.finished,
    )
end

function simulate_tcp_reno(
    prop_delay_ms::AbstractVector{<:Real},
    data_rate_bps::Real;
    max_packets::Int=64,
    kwargs...,
)
    hops = [PathHop(d / 1000.0, data_rate_bps; max_packets=max_packets) for d in prop_delay_ms]
    return simulate_tcp_reno(TcpRenoConfig(hops; kwargs...))
end

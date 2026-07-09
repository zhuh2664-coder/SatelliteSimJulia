# Simplified TCP CUBIC over a multi-hop DES path (single flow)

export TcpCubicConfig, TcpCubicResult, simulate_tcp_cubic

"""
    TcpCubicConfig

Same path model as Reno, but congestion avoidance uses CUBIC window growth
(RFC 8312 simplified: W(t) = C(t-K)³ + W_max).
"""
struct TcpCubicConfig
    hops::Vector{PathHop}
    mss_bytes::Int
    total_bytes::Int
    rto_s::Float64
    init_cwnd::Int
    ssthresh::Int
    seed::Int
    C::Float64
    beta::Float64
end

function TcpCubicConfig(
    hops::Vector{PathHop};
    mss_bytes::Int=1460,
    total_bytes::Int=50_000,
    rto_s::Real=0.5,
    init_cwnd::Int=1,
    ssthresh::Int=32,
    seed::Int=1,
    C::Real=0.4,
    beta::Real=0.7,
)
    isempty(hops) && throw(ArgumentError("hops must be non-empty"))
    return TcpCubicConfig(
        hops, mss_bytes, total_bytes, Float64(rto_s), init_cwnd, ssthresh, seed,
        Float64(C), Float64(beta),
    )
end

struct TcpCubicResult
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
    w_max::Float64
end

mutable struct _TcpCubicState
    queues::Vector{AbstractQueue}
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
    # CUBIC
    C::Float64
    beta::Float64
    w_max::Float64
    epoch_start::Float64
    K::Float64
    in_cong_avoid::Bool
end

function _cubic_K(w_max::Float64, beta::Float64, C::Float64)
    w_max <= 0 && return 0.0
    return cbrt(w_max * (1 - beta) / C)
end

function _cubic_w(st::_TcpCubicState, t::Float64)
    # W(t) = C*(t-K)^3 + W_max
    dt = t - st.epoch_start
    return st.C * (dt - st.K)^3 + st.w_max
end

@resumable function _tcp_cubic_deliver(env, st::_TcpCubicState, seq::Int, size::Int)
    for h in 1:length(st.queues)
        pkt = create_packet!(size, UInt32(1), UInt32(2); protocol=UInt8(6))
        _sync_queue_time!(st.queues[h], ConcurrentSim.now(env))
        if !enqueue!(st.queues[h], pkt)
            st.drops += 1
            return
        end
        start = max(ConcurrentSim.now(env), st.busy_until[h])
        st.busy_until[h] = start + st.services[h]
        wait = start - ConcurrentSim.now(env)
        @yield ConcurrentSim.timeout(env, wait + st.services[h])
        _sync_queue_time!(st.queues[h], ConcurrentSim.now(env))
        out = dequeue!(st.queues[h])
        if out === nothing
            st.drops += 1
            return
        end
        @yield ConcurrentSim.timeout(env, st.prop_s[h])
    end
    @yield ConcurrentSim.timeout(env, sum(st.prop_s))
    push!(st.acked, seq)
end

@resumable function _tcp_cubic_sender(env, st::_TcpCubicState)
    while st.bytes_acked < st.total_bytes
        outstanding = count(seq -> !(seq in st.acked), keys(st.send_time))
        while outstanding < floor(Int, st.cwnd) && st.next_seq < st.total_bytes
            seq = st.next_seq
            size = min(st.mss, st.total_bytes - seq)
            st.next_seq += size
            st.segments_sent += 1
            st.send_time[seq] = ConcurrentSim.now(env)
            @process _tcp_cubic_deliver(env, st, seq, size)
            outstanding += 1
        end

        t_wait_start = ConcurrentSim.now(env)
        got = false
        ack_seq = 0
        while ConcurrentSim.now(env) - t_wait_start < st.rto_s
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
            while st.una < st.next_seq && !(st.una in keys(st.send_time))
                st.una += st.mss
            end

            now = ConcurrentSim.now(env)
            if st.cwnd < st.ssthresh
                # slow start
                st.cwnd += 1.0
                st.in_cong_avoid = false
            else
                if !st.in_cong_avoid
                    st.in_cong_avoid = true
                    st.w_max = max(st.w_max, st.cwnd)
                    st.epoch_start = now
                    st.K = _cubic_K(st.w_max, st.beta, st.C)
                end
                w_cub = _cubic_w(st, now)
                # TCP-friendly region: at least Reno-like 1/cwnd per ACK
                w_reno = st.cwnd + 1.0 / max(st.cwnd, 1.0)
                st.cwnd = max(w_cub, w_reno)
            end
        else
            if !isempty(st.send_time)
                seq = minimum(keys(st.send_time))
                size = min(st.mss, st.total_bytes - seq)
                st.retransmits += 1
                st.segments_sent += 1
                st.w_max = st.cwnd
                st.ssthresh = max(floor(st.cwnd * st.beta), 2.0)
                st.cwnd = st.ssthresh
                st.in_cong_avoid = false
                st.epoch_start = ConcurrentSim.now(env)
                st.K = _cubic_K(st.w_max, st.beta, st.C)
                st.send_time[seq] = ConcurrentSim.now(env)
                @process _tcp_cubic_deliver(env, st, seq, size)
            end
        end
    end
    st.finish_time = ConcurrentSim.now(env)
    st.finished = true
end

"""
    simulate_tcp_cubic(cfg) -> TcpCubicResult
"""
function simulate_tcp_cubic(cfg::TcpCubicConfig)::TcpCubicResult
    Random.seed!(cfg.seed)
    reset_packet_counter!()

    nhops = length(cfg.hops)
    services = [cfg.mss_bytes * 8 / h.data_rate_bps for h in cfg.hops]
    prop_s = [h.prop_delay_s for h in cfg.hops]
    queues = make_path_queues(cfg.hops, cfg.mss_bytes, :droptail)

    st = _TcpCubicState(
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
        cfg.C,
        cfg.beta,
        Float64(cfg.ssthresh),
        0.0,
        0.0,
        false,
    )

    env = ConcurrentSim.Simulation()
    @process _tcp_cubic_sender(env, st)
    ConcurrentSim.run(env, 120.0)

    dur = isnan(st.finish_time) ? ConcurrentSim.now(env) : st.finish_time
    goodput = dur > 0 ? st.bytes_acked * 8.0 / dur : 0.0
    mean_rtt = st.rtt_n > 0 ? st.rtt_sum / st.rtt_n : NaN
    return TcpCubicResult(
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
        st.w_max,
    )
end

function simulate_tcp_cubic(
    prop_delay_ms::AbstractVector{<:Real},
    data_rate_bps::Real;
    max_packets::Int=64,
    kwargs...,
)
    hops = [PathHop(d / 1000.0, data_rate_bps; max_packets=max_packets) for d in prop_delay_ms]
    return simulate_tcp_cubic(TcpCubicConfig(hops; kwargs...))
end

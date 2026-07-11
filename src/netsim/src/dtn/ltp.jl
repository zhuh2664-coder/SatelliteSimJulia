# Licklider Transmission Protocol — red/green parts (RFC 5326 subset)

export LTP_RED, LTP_GREEN
export LtpHeader, LtpSegment, LtpSession
export ltp_segment!, ltp_ack_red!, ltp_pending_red, ltp_retransmit_red
export ltp_reassemble_red, ltp_reassemble_green, ltp_stats
export LtpTransferResult, simulate_ltp_transfer

const LTP_RED = UInt8(0)
const LTP_GREEN = UInt8(1)

struct LtpHeader
    session::UInt64
    segment::UInt64
    offset::UInt64
    length::UInt32
end

mutable struct LtpSegment
    header::LtpHeader
    partition::UInt8
    data::Vector{UInt8}
    is_checkpoint::Bool
end

"""
    LtpSession

One block transfer split into red (reliable) and green (best-effort) parts.
"""
mutable struct LtpSession
    session_id::UInt64
    src::UInt64
    dst::UInt64
    segment_size::Int
    red_segments::Vector{LtpSegment}
    green_segments::Vector{LtpSegment}
    red_acked::Set{Int}
    red_pending::Set{Int}
    checkpoints::Int
end

function LtpSession(session_id::Integer, src::Integer, dst::Integer; segment_size::Int=1400)
    segment_size > 0 || throw(ArgumentError("segment_size must be positive"))
    return LtpSession(
        UInt64(session_id), UInt64(src), UInt64(dst), segment_size,
        LtpSegment[], LtpSegment[], Set{Int}(), Set{Int}(), 0,
    )
end

"""
    ltp_segment!(sess, data; red_bytes=length(data))

Split `data` into red (first `red_bytes`) and green segments.
"""
function ltp_segment!(sess::LtpSession, data::Vector{UInt8}; red_bytes::Integer=length(data))
    empty!(sess.red_segments)
    empty!(sess.green_segments)
    empty!(sess.red_acked)
    empty!(sess.red_pending)
    sess.checkpoints = 0

    red_len = clamp(Int(red_bytes), 0, length(data))
    red = @view data[1:red_len]
    green = @view data[red_len+1:end]

    seg_num = 0
    for start in 1:sess.segment_size:length(red)
        seg_num += 1
        stop = min(start + sess.segment_size - 1, length(red))
        chunk = Vector{UInt8}(red[start:stop])
        is_cp = (seg_num % 4 == 0) || (stop == length(red))
        is_cp && (sess.checkpoints += 1)
        push!(sess.red_segments, LtpSegment(
            LtpHeader(sess.session_id, UInt64(seg_num), UInt64(start - 1), UInt32(length(chunk))),
            LTP_RED, chunk, is_cp,
        ))
        push!(sess.red_pending, seg_num)
    end

    for start in 1:sess.segment_size:length(green)
        seg_num += 1
        stop = min(start + sess.segment_size - 1, length(green))
        chunk = Vector{UInt8}(green[start:stop])
        push!(sess.green_segments, LtpSegment(
            LtpHeader(sess.session_id, UInt64(seg_num), UInt64(start - 1), UInt32(length(chunk))),
            LTP_GREEN, chunk, false,
        ))
    end
    return sess
end

ltp_pending_red(sess::LtpSession) = sort!(collect(sess.red_pending))

function ltp_ack_red!(sess::LtpSession, seg_nums::AbstractVector{<:Integer})
    for n in seg_nums
        i = Int(n)
        if i in sess.red_pending
            delete!(sess.red_pending, i)
            push!(sess.red_acked, i)
        end
    end
    return sess
end

function ltp_retransmit_red(sess::LtpSession)::Vector{LtpSegment}
    return [sess.red_segments[i] for i in ltp_pending_red(sess)]
end

function ltp_reassemble_red(sess::LtpSession)::Union{Vector{UInt8},Nothing}
    isempty(sess.red_pending) || return nothing
    out = UInt8[]
    for seg in sess.red_segments
        append!(out, seg.data)
    end
    return out
end

function ltp_reassemble_green(sess::LtpSession)::Vector{UInt8}
    out = UInt8[]
    for seg in sess.green_segments
        append!(out, seg.data)
    end
    return out
end

function ltp_stats(sess::LtpSession)
    return (
        red_segments=length(sess.red_segments),
        green_segments=length(sess.green_segments),
        red_pending=length(sess.red_pending),
        red_acked=length(sess.red_acked),
        checkpoints=sess.checkpoints,
    )
end

struct LtpTransferResult
    delivered_red::Bool
    red_bytes::Int
    green_bytes_rx::Int
    green_bytes_tx::Int
    segments_sent::Int
    retransmits::Int
    drops::Int
    duration_s::Float64
end

# Module-scope resumable (ConcurrentSim requirement)
mutable struct _LtpSimState
    sess::LtpSession
    prop_delay_s::Float64
    rate_bps::Float64
    loss::Float64
    max_rounds::Int
    sent::Int
    drops::Int
    rexmit::Int
    green_rx::Int
    finished::Bool
    finish_time::Float64
end

@resumable function _ltp_engine(env, st::_LtpSimState)
    for seg in st.sess.green_segments
        tx_s = length(seg.data) * 8 / st.rate_bps
        @yield ConcurrentSim.timeout(env, tx_s)
        st.sent += 1
        @yield ConcurrentSim.timeout(env, st.prop_delay_s)
        if rand() >= st.loss
            st.green_rx += length(seg.data)
        else
            st.drops += 1
        end
    end

    round = 0
    while !isempty(st.sess.red_pending) && round < st.max_rounds
        round += 1
        pending = ltp_pending_red(st.sess)
        round > 1 && (st.rexmit += length(pending))
        acked_this = Int[]
        for i in pending
            seg = st.sess.red_segments[i]
            tx_s = length(seg.data) * 8 / st.rate_bps
            @yield ConcurrentSim.timeout(env, tx_s)
            st.sent += 1
            @yield ConcurrentSim.timeout(env, st.prop_delay_s)
            if rand() >= st.loss
                push!(acked_this, i)
            else
                st.drops += 1
            end
        end
        @yield ConcurrentSim.timeout(env, st.prop_delay_s)  # RS/RA RTT
        ltp_ack_red!(st.sess, acked_this)
    end
    st.finished = isempty(st.sess.red_pending)
    st.finish_time = ConcurrentSim.now(env)
end

"""
    simulate_ltp_transfer(data; red_bytes, prop_delay_s, rate_bps, loss, ...)

DES transfer of one LTP block over a single hop with Bernoulli segment loss.
Red part is retransmitted until complete (or max_rounds); green is best-effort.
"""
function simulate_ltp_transfer(
    data::Vector{UInt8};
    red_bytes::Integer=length(data),
    segment_size::Int=500,
    prop_delay_s::Real=0.05,
    rate_bps::Real=10e6,
    loss::Real=0.0,
    max_rounds::Int=20,
    seed::Int=1,
)
    0.0 <= loss < 1.0 || throw(ArgumentError("loss must be in [0,1)"))
    Random.seed!(seed)
    sess = LtpSession(1, 1, 2; segment_size=segment_size)
    ltp_segment!(sess, data; red_bytes=red_bytes)

    st = _LtpSimState(
        sess, Float64(prop_delay_s), Float64(rate_bps), Float64(loss), max_rounds,
        0, 0, 0, 0, false, NaN,
    )
    env = ConcurrentSim.Simulation()
    @process _ltp_engine(env, st)
    ConcurrentSim.run(env, 3600.0)

    red = ltp_reassemble_red(sess)
    return LtpTransferResult(
        red !== nothing,
        red === nothing ? 0 : length(red),
        st.green_rx,
        sum(length(s.data) for s in sess.green_segments; init=0),
        st.sent,
        st.rexmit,
        st.drops,
        isnan(st.finish_time) ? ConcurrentSim.now(env) : st.finish_time,
    )
end

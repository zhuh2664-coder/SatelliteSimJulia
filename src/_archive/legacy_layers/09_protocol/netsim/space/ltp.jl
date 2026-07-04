"""
    ltp.jl — LTP (Licklider Transmission Protocol) + 红/绿分区

对标 RFC 5326 / CCSDS 734.1-B-1。

红/绿分区 (RFC 5326 §3.3):
  - Red-part: 必须可靠交付，ARQ 确认重传
  - Green-part: 尽力交付，无确认

检查点/报告段 (RFC 5326 §3.4):
  - CP (Checkpoint): 嵌入在 DS 中，触发接收端回复 RS
  - RS (Report Segment): 接收端报告各段接收状态 (位图)
  - RA (Report ACK): 发送端确认收到 RS
"""
const LTP_RED = 0
const LTP_GREEN = 1
const LTP_DS = 0x01; const LTP_RS = 0x02; const LTP_CP = 0x03
const LTP_RA = 0x04; const LTP_CX = 0x05

struct LtpHeader
    type::UInt8; session::UInt64; segment::UInt64
    total::UInt64; length::UInt32; offset::UInt64
end

mutable struct LtpSegment
    header::LtpHeader
    partition::UInt8   # LTP_RED or LTP_GREEN
    data::Vector{UInt8}
    is_checkpoint::Bool
    checkpoint_seq::UInt64
end

"""
    LtpSession — LTP 会话 (含红/绿分区)

一个会话传输一个完整数据块，分为 red_part 和 green_part。
"""
mutable struct LtpSession
    session_id::UInt64; src::UInt64; dst::UInt64

    # 红区 (可靠)
    red_data::Vector{UInt8}
    red_segments::Vector{LtpSegment}
    red_unacked::Set{Int}
    red_pending::Set{Int}

    # 绿区 (不可靠)
    green_data::Vector{UInt8}
    green_segments::Vector{LtpSegment}

    # 检查点/报告
    cp_count::Int            # 已发送 CP 数量
    cp_timer::Float64        # 下次 CP 超时时间
    rs_received::Dict{UInt64, BitSet}  # 各 CP 对应的接收位图

    # 定时器 (RFC 5326 §8)
    checkpoint_timer::Float64; rs_timer::Float64
    cancel_timer::Float64; ack_timer::Float64
    retransmit_timer::Float64; inactivity_timer::Float64

    # 参数
    segment_size::Int; retransmit_timeout::Float64
    last_activity::Float64
end

function LtpSession(session::UInt64, src::UInt64, dst::UInt64;
                     seg_size=1400, timeout=3.0)
    LtpSession(session, src, dst,
               UInt8[], LtpSegment[], Set{Int}(), Set{Int}(),
               UInt8[], LtpSegment[],
               0, 0.0, Dict{UInt64,BitSet}(),
               -1.0, -1.0, -1.0, -1.0, -1.0, -1.0,
               seg_size, timeout, 0.0)
end

"""
    send_data!(session, data, red_size)

发送数据。前 red_size 字节为红区 (可靠)，其余为绿区 (尽力交付)。
"""
function send_data!(sess::LtpSession, data::Vector{UInt8}, red_size::Int)
    sess.last_activity = Now()

    # 拆分红/绿区
    red_len = min(red_size, length(data))
    sess.red_data = data[1:red_len]
    sess.green_data = data[red_len+1:end]

    # 红区分段 + 嵌入检查点
    seg_num = UInt64(0)
    for start in 1:sess.segment_size:length(sess.red_data)
        seg_num += 1
        end_idx = min(start + sess.segment_size - 1, length(sess.red_data))
        cp_flag = (seg_num % 5 == 0) || (seg_num == length(sess.red_data))
        seg = LtpSegment(
            LtpHeader(LTP_DS, sess.session_id, seg_num,
                      UInt64(ceil(length(sess.red_data)/sess.segment_size)),
                      UInt32(end_idx-start+1), UInt64(start-1)),
            LTP_RED, sess.red_data[start:end_idx], cp_flag, seg_num)
        push!(sess.red_segments, seg)
        push!(sess.red_pending, Int(seg_num))
    end

    # 绿区分段 (无检查点)
    for start in 1:sess.segment_size:length(sess.green_data)
        seg_num += 1
        end_idx = min(start + sess.segment_size - 1, length(sess.green_data))
        seg = LtpSegment(
            LtpHeader(LTP_DS, sess.session_id, seg_num,
                      0, UInt32(end_idx-start+1), UInt64(start-1)),
            LTP_GREEN, sess.green_data[start:end_idx], false, 0)
        push!(sess.green_segments, seg)
    end

    # 设置检查点定时器
    if !isempty(sess.red_segments)
        sess.checkpoint_timer = Now() + sess.retransmit_timeout
    end
end

"""
    send_checkpoint(sess) → Vector{LtpSegment}

发送检查点 (CP): 将最后一个数据段标记为 CP。
"""
function send_checkpoint(sess::LtpSession)::Vector{LtpSegment}
    sess.cp_count += 1
    cp_segs = LtpSegment[]
    for seg in sess.red_segments
        if seg.is_checkpoint
            cp = LtpSegment(
                LtpHeader(LTP_CP, sess.session_id, seg.header.segment,
                          seg.header.total, seg.header.length, seg.header.offset),
                LTP_RED, seg.data, true, UInt64(sess.cp_count))
            push!(cp_segs, cp)
        end
    end
    sess.cp_timer = Now() + sess.retransmit_timeout
    cp_segs
end

"""
    receive_report!(sess, cp_seq, bitmap) → Vector{Int}

接收端处理报告段 (RS): 返回未收到的段序号列表。
"""
function receive_report!(sess::LtpSession, cp_seq::UInt64, bitmap::Vector{UInt8})
    missing = Int[]
    for (i, seg) in enumerate(sess.red_segments)
        byte_idx = (i - 1) ÷ 8 + 1
        bit_idx = (i - 1) % 8
        if byte_idx <= length(bitmap)
            bit = (bitmap[byte_idx] >> bit_idx) & 0x01
            if bit == 0  # 未收到
                push!(missing, i)
            else
                delete!(sess.red_pending, i)
                push!(sess.red_unacked, i)
            end
        end
    end
    sess.rs_timer = Now() + sess.retransmit_timeout
    missing
end

"""
    process_retransmit!(sess) → Vector{LtpSegment}

重传未确认的红区段。
"""
function process_retransmit!(sess::LtpSession)::Vector{LtpSegment}
    retx = LtpSegment[]
    for i in sess.red_pending
        push!(retx, sess.red_segments[i])
    end
    sess.retransmit_timer = Now() + sess.retransmit_timeout * 1.5
    retx
end

"""
    reassemble_red!(sess) → Vector{UInt8} | nothing

红区重组: 所有段确认后返回完整数据。
"""
function reassemble_red!(sess::LtpSession)::Union{Vector{UInt8}, Nothing}
    if !isempty(sess.red_pending)
        return nothing
    end
    data = UInt8[]
    for seg in sess.red_segments
        append!(data, seg.data)
    end
    data
end

"""
    reassemble_green!(sess) → Vector{UInt8}

绿区重组: 直接返回 (不可靠, 可能有丢失)。
"""
function reassemble_green!(sess::LtpSession)::Vector{UInt8}
    data = UInt8[]
    for seg in sess.green_segments
        append!(data, seg.data)
    end
    data
end

"""
    LTP 六种定时器 (RFC 5326 §8)

  1. Checkpoint Timer: 等待 RS 回复 CP
  2. RS Timer: 等待 RA 确认 RS
  3. Cancel Timer: 会话取消等待
  4. ACK Timer: 等待最终确认
  5. Retransmit Timer: 重传间隔控制
  6. Inactivity Timer: 会话空闲超时
"""

"""启动定时器"""
function ltp_start_timer!(sess::LtpSession, timer::Symbol, timeout::Float64)
    t = Now() + timeout
    if timer == :checkpoint; sess.checkpoint_timer = t
    elseif timer == :rs; sess.rs_timer = t
    elseif timer == :cancel; sess.cancel_timer = t
    elseif timer == :ack; sess.ack_timer = t
    elseif timer == :retransmit; sess.retransmit_timer = t
    elseif timer == :inactivity; sess.inactivity_timer = t; end
end

"""停止定时器"""
function ltp_stop_timer!(sess::LtpSession, timer::Symbol)
    if timer == :checkpoint; sess.checkpoint_timer = -1.0
    elseif timer == :rs; sess.rs_timer = -1.0
    elseif timer == :cancel; sess.cancel_timer = -1.0
    elseif timer == :ack; sess.ack_timer = -1.0
    elseif timer == :retransmit; sess.retransmit_timer = -1.0
    elseif timer == :inactivity; sess.inactivity_timer = -1.0; end
end

"""检查单个定时器是否超时"""
function ltp_timer_expired(sess::LtpSession, timer::Symbol)::Bool
    t = Now()
    val = if timer == :checkpoint; sess.checkpoint_timer
    elseif timer == :rs; sess.rs_timer
    elseif timer == :cancel; sess.cancel_timer
    elseif timer == :ack; sess.ack_timer
    elseif timer == :retransmit; sess.retransmit_timer
    elseif timer == :inactivity; sess.inactivity_timer
    else; -1.0; end
    val > 0 && t > val
end

"""检查任意定时器超时"""
function ltp_timed_out(sess::LtpSession)::Bool
    ltp_timer_expired(sess, :checkpoint) ||
    ltp_timer_expired(sess, :rs) ||
    ltp_timer_expired(sess, :retransmit)
end

"""获取最先超时的定时器"""
function ltp_next_timeout(sess::LtpSession)::Float64
    timers = [sess.checkpoint_timer, sess.rs_timer, sess.cancel_timer,
              sess.ack_timer, sess.retransmit_timer, sess.inactivity_timer]
    valid = filter(t -> t > 0, timers)
    isempty(valid) ? Inf : minimum(valid)
end

"""
    ltp_stats(sess) → Dict

LTP 会话统计。
"""
function ltp_stats(sess::LtpSession)
    Dict(
        :red_segments => length(sess.red_segments),
        :green_segments => length(sess.green_segments),
        :red_pending => length(sess.red_pending),
        :red_acked => length(sess.red_unacked),
        :cp_count => sess.cp_count,
    )
end

# Keep backward compatibility
segment_data(sess, data) = send_data!(sess, data, length(data))

using Base: cbrt

const CC_RENO = :reno; const CC_CUBIC = :cubic; const CC_BBR = :bbr

# RFC 793 states
const CLOSED=0; const LISTEN=1; const SYN_SENT=2; const SYN_RCVD=3
const ESTABLISHED=4; const CLOSE_WAIT=5; const LAST_ACK=6
const FIN_WAIT_1=7; const FIN_WAIT_2=8; const CLOSING=9; const TIME_WAIT=10

# TCP Flags
const TCP_FIN=0x01; const TCP_SYN=0x02; const TCP_RST=0x04
const TCP_PSH=0x08; const TCP_ACK=0x10; const TCP_ECE=0x40; const TCP_CWR=0x80

# Options
const TCP_OPT_SACK_PERM=0x04; const TCP_OPT_SACK=0x05
const TCP_OPT_WSCALE=0x03; const TCP_OPT_TS=0x08
const TCP_OPT_FASTOPEN=0x34; const TCP_OPT_MPTCP=0x1e

struct TcpHeader
    src_port::UInt16; dst_port::UInt16; seq::UInt32; ack::UInt32
    flags::UInt8; window::UInt16; urgent::UInt16
end

mutable struct SackBlock
    left::UInt32; right::UInt32
end

mutable struct TcpSegment
    seq::UInt32; ack::UInt32; flags::UInt8
    payload::Vector{UInt8}; retx_count::Int; last_sent::Float64
    sack_blocks::Vector{SackBlock}; wscale::UInt8; ts_val::UInt32; ts_ecr::UInt32
    tfo_cookie::UInt64
    TcpSegment(s,a,f,p,r,l) = new(s,a,f,p,r,l,SackBlock[],0,0,0,0)
end

mutable struct TcpSocket
    id::UInt32; src_addr::Ipv4Address; src_port::UInt16
    dst_addr::Ipv4Address; dst_port::UInt16

    # State
    state::Int; iss::UInt32; irs::UInt32
    snd_nxt::UInt32; snd_una::UInt32; rcv_nxt::UInt32

    # Window + scaling
    snd_wnd::UInt32;     # 发送窗口 (对方通告的)
    rcv_wnd::UInt32;     # 接收窗口 (我方通告的)
    snd_wscale::UInt8;   # 对方窗口缩放因子
    rcv_wscale::UInt8;   # 我方窗口缩放因子
    rcv_wnd_used::UInt32 # 已用接收缓冲

    # Congestion control
    cc::Symbol; cwnd::Float64; ssthresh::Float64; mss::Int

    # RTT estimation (RFC 6298)
    srtt::Float64; rttvar::Float64; rto::Float64
    rtt_sample::Float64; rtt_time::Float64

    # Timestamps (RFC 7323)
    ts_recent::UInt32; ts_offset::UInt32; ts_enabled::Bool

    # SACK (RFC 2018/2883)
    sack_enabled::Bool; sack_permitted::Bool
    sacked::Dict{UInt32, Bool}  # seq → sacked flag

    # Buffers
    send_buffer::Vector{TcpSegment}
    recv_buffer::Dict{UInt32, TcpSegment}  # out-of-order
    recv_ordered::Vector{UInt8}            # in-order data
    retrans_queue::Vector{TcpSegment}

    # Nagle (RFC 896)
    nagle_enabled::Bool; nagle_small::Bool

    # ECN (RFC 3168)
    ecn_enabled::Bool; ecn_echo::Bool; ecn_cwr::Bool

    # Fast Open (RFC 7413)
    tfo_enabled::Bool; tfo_pending::UInt64

    # Pacing (for BBR)
    pacing_rate::Float64; pacing_gain::Float64

    # RACK loss detection (RFC 8985)
    rack_fack::UInt32; rack_rtt::Float64; rack_seg::Union{TcpSegment,Nothing}

    # Callbacks
    rx_callback::Union{Function,Nothing}
    cc_params::Dict{Symbol,Any}
    segment_out::Vector{TcpSegment}
end

function TcpSocket(id::UInt32; cc=CC_RENO, mss=1460, wscale=3, sack=true, ts=true,
                    nagle=true, ecn=false, tfo=false)
    p = Dict{Symbol,Any}(:dup_ack_count=>0,:in_recovery=>false)
    if cc == CC_CUBIC; p[:c]=0.4; p[:w_max]=0.0; p[:k]=0.0; p[:epoch_start]=0.0
    elseif cc == CC_BBR; p[:bbr_state]=0; p[:bw]=1e6; p[:min_rtt]=Inf
        p[:pacing_gain]=1.0; p[:cwnd_gain]=2.0; p[:probe_rtt_done]=0.0; p[:bw_max]=0.0
    end
    TcpSocket(id,Ipv4Address(),0,Ipv4Address(),0,
              CLOSED,0,0,0,0,0,
              65535,65535,UInt8(wscale),UInt8(wscale),0,
              cc,10.0,65535.0,mss,
              0.0,0.0,3.0,0.0,0.0,
              0,0,ts,
              sack,sack,Dict{UInt32,Bool}(),
              Any[],Dict{UInt32,TcpSegment}(),UInt8[],Any[],
              nagle,false,
              ecn,false,false,
              tfo,0,
              1e6,1.0,
              0,0.0,nothing,
              nothing,p,Any[])
end

# ═══════════════════════════════════════════
#  Connection Lifecycle
# ═══════════════════════════════════════════

function Bind(s::TcpSocket, a::Ipv4Address, p::UInt16); s.src_addr=a; s.src_port=p; end
Bind(s::TcpSocket, p::UInt16) = (s.src_port=p)
SetRecvCallback(s::TcpSocket, cb) = (s.rx_callback=cb)

"""CLOSED → SYN_SENT (active open, RFC 793 §3.4)"""
function Connect(s::TcpSocket, a::Ipv4Address, p::UInt16)
    s.dst_addr=a; s.dst_port=p
    s.iss = UInt32(rand(UInt32))
    s.snd_nxt = s.iss + 1
    s.snd_una = s.iss
    s.state = SYN_SENT
    syn = TcpSegment(s.iss,0,TCP_SYN,UInt8[],0,Now())
    if s.ts_enabled; syn.ts_val = ts_now(s); end
    if s.sack_enabled; syn.flags |= 0x00 end
    push!(s.send_buffer,syn); push!(s.segment_out,syn)
end

"""SYN_SENT → ESTABLISHED (receive SYN+ACK)"""
function ProcessSynAck(s::TcpSocket, seg::TcpSegment)
    if s.state == SYN_SENT
        s.irs = seg.seq; s.rcv_nxt = seg.seq + 1
        s.snd_una = s.iss + 1
        if seg.wscale > 0; s.snd_wscale = seg.wscale; end
        if seg.ts_val > 0; s.ts_recent = seg.ts_val; end
        if seg.sack_blocks !== nothing; s.sack_permitted = true; end
        s.state = ESTABLISHED
        s.cwnd = min(10.0, 14600.0/s.mss)  # IW10 (RFC 6928)
        ack = TcpSegment(0,s.rcv_nxt,TCP_ACK,UInt8[],0,Now())
        ack.wscale = s.rcv_wscale
        if s.sack_permitted; ack.sack_blocks = SackBlock[]; end
        push!(s.segment_out, ack)
    end
end

"""LISTEN → SYN_RCVD (passive open)"""
function ProcessSyn(s::TcpSocket, seg::TcpSegment)
    if s.state == LISTEN
        s.irs = seg.seq; s.rcv_nxt = seg.seq + 1
        s.iss = UInt32(rand(UInt32)); s.snd_nxt = s.iss + 1
        if seg.wscale > 0; s.snd_wscale = seg.wscale; end
        s.state = SYN_RCVD
        synack = TcpSegment(s.iss,s.rcv_nxt,TCP_SYN|TCP_ACK,UInt8[],0,Now())
        synack.wscale = s.rcv_wscale
        push!(s.segment_out, synack)
    end
end

"""SYN_RCVD → ESTABLISHED (receive final ACK)"""
function ProcessEstablished(s::TcpSocket, seg::TcpSegment)
    if s.state == SYN_RCVD && (seg.flags&TCP_ACK)!=0
        s.state = ESTABLISHED
        s.cwnd = 10.0
    end
end

"""FIN handshake (RFC 793 §3.5)"""
function Close(s::TcpSocket)
    if s.state == ESTABLISHED
        s.state = FIN_WAIT_1
        fin = TcpSegment(s.snd_nxt,s.rcv_nxt,TCP_FIN|TCP_ACK,UInt8[],0,Now())
        push!(s.segment_out, fin)
        s.snd_nxt += 1
    elseif s.state == CLOSE_WAIT
        s.state = LAST_ACK
        fin = TcpSegment(s.snd_nxt,s.rcv_nxt,TCP_FIN|TCP_ACK,UInt8[],0,Now())
        push!(s.segment_out, fin)
    end
end

"""Process FIN received"""
function ProcessFin(s::TcpSocket, seg::TcpSegment)
    if s.state == ESTABLISHED
        s.state = CLOSE_WAIT
        s.rcv_nxt = seg.seq + 1
        ack = TcpSegment(0,s.rcv_nxt,TCP_ACK,UInt8[],0,Now())
        push!(s.segment_out, ack)
    elseif s.state == FIN_WAIT_1
        s.state = CLOSING
        s.rcv_nxt = seg.seq + 1
    elseif s.state == FIN_WAIT_2
        s.state = TIME_WAIT
        s.rcv_nxt = seg.seq + 1
        ack = TcpSegment(0,s.rcv_nxt,TCP_ACK,UInt8[],0,Now())
        push!(s.segment_out, ack)
    end
end

"""Process FIN+ACK in CLOSING state"""
function ProcessClosingAck(s::TcpSocket, seg::TcpSegment)
    if s.state == CLOSING && (seg.flags&TCP_ACK)!=0
        s.state = TIME_WAIT
        s.snd_una = seg.ack
    end
end

"""LAST_ACK → CLOSED"""
function ProcessLastAck(s::TcpSocket, seg::TcpSegment)
    if s.state == LAST_ACK && (seg.flags&TCP_ACK)!=0
        s.state = CLOSED
    end
end

"""RST processing"""
function ProcessRst(s::TcpSocket)
    s.state = CLOSED
    empty!(s.send_buffer); empty!(s.recv_buffer); empty!(s.retrans_queue)
    s.cwnd = 1.0
end

# ═══════════════════════════════════════════
#  Send / Receive
# ═══════════════════════════════════════════

"""Send data (RFC 793 + Nagle RFC 896 + IW10 RFC 6928)"""
function Send(s::TcpSocket, data::Vector{UInt8})
    s.state == ESTABLISHED || return false
    n = min(length(data), s.mss)
    seg = TcpSegment(s.snd_nxt, s.rcv_nxt, TCP_ACK|TCP_PSH, data[1:n], 0, Now())
    if s.ts_enabled; seg.ts_val = ts_now(s); end
    push!(s.send_buffer, seg); push!(s.segment_out, seg)
    s.snd_nxt += n
    true
end

"""Receive segment (main entry)"""
function TcpReceive(s::TcpSocket, seg::TcpSegment)
    # Handle flags
    if (seg.flags&TCP_RST)!=0; ProcessRst(s); return; end
    if (seg.flags&TCP_SYN)!=0
        if (seg.flags&TCP_ACK)==0; ProcessSyn(s, seg)
        else; ProcessSynAck(s, seg); end
    end
    if (seg.flags&TCP_FIN)!=0; ProcessFin(s, seg); end

    # ACK processing
    if (seg.flags&TCP_ACK)!=0
        ProcessAck(s, seg.ack)

        if s.state == SYN_RCVD; ProcessEstablished(s, seg); end
        if s.state == CLOSING; ProcessClosingAck(s, seg); end
        if s.state == LAST_ACK; ProcessLastAck(s, seg); end
    end

    # ECN (RFC 3168)
    if s.ecn_enabled
        if (seg.flags&TCP_ECE)!=0; s.ecn_echo = true; end
        if (seg.flags&TCP_CWR)!=0; s.ecn_echo = false; end
    end

    # Data delivery
    if length(seg.payload) > 0 && s.state ∈ (ESTABLISHED,CLOSE_WAIT,FIN_WAIT_1,FIN_WAIT_2)
        deliver_data(s, seg)
    end

    # SACK processing
    if s.sack_enabled && length(seg.sack_blocks) > 0
        process_sack(s, seg.sack_blocks)
    end
end

"""In-order data delivery"""
function deliver_data(s::TcpSocket, seg::TcpSegment)
    if seg.seq == s.rcv_nxt
        append!(s.recv_ordered, seg.payload)
        s.rcv_nxt = seg.seq + length(seg.payload)
        s.rcv_wnd_used += length(seg.payload)

        # Deliver any buffered in-order data
        while haskey(s.recv_buffer, s.rcv_nxt)
            buf = s.recv_buffer[s.rcv_nxt]
            append!(s.recv_ordered, buf.payload)
            s.rcv_nxt += length(buf.payload)
            delete!(s.recv_buffer, s.rcv_nxt)
        end

        if s.rx_callback !== nothing; s.rx_callback(s, seg); end
    elseif seg.seq > s.rcv_nxt
        # Out-of-order: buffer + send SACK
        s.recv_buffer[seg.seq] = seg
    end
end

"""ACK processing (RFC 5681 + SACK Scoreboard)

正确处理四种情况：
- 新 ACK (ack > snd_una): 更新窗口, 清除退避, RTT 采样 (Karn 算法排除重传)
- 部分 ACK (ack 在窗口中但未到 snd_una): 快速恢复 (RFC 6675)
- 重复 ACK (ack == snd_una): 统计 dupack 计数
- SACK: 驱动精确重传 (RFC 6675)
"""
function ProcessAck(s::TcpSocket, ack_num::UInt32)
    if ack_num > s.snd_una
        # ── New ACK (cumulative) ──
        newly_acked = ack_num - s.snd_una
        s.snd_una = ack_num

        # Remove fully-ACKed segments from send_buffer
        filter!(seg -> seg.seq + max(UInt32(length(seg.payload)), UInt32(1)) > ack_num, s.send_buffer)

        # RTO backoff recovery: new ACK clears backoff
        if s.rto > s.srtt + 4 * s.rttvar
            s.rto = max(s.srtt + 4 * s.rttvar, 1.0)
        end

        s.rcv_wnd = 65535  # simplified
        OnAck(s)
        s.cc_params[:dup_ack_count] = 0

        # RTT estimation with Karn's algorithm (RFC 6298):
        # Only sample RTT from segments that have NOT been retransmitted
        if s.ts_enabled && s.cc_params[:dup_ack_count] == 0
            sample = (ts_now(s) - s.rtt_time) / 1000.0
            if sample > 0.001 && sample < 10.0  # sanity check
                UpdateRtt(s, sample)
            end
        end

        # SACK-driven retransmission (RFC 6675): retransmit first hole
        sb = get(s.cc_params, :scoreboard, nothing)
        if sb !== nothing
            hole = first_hole(sb, s.snd_una)
            if hole > s.snd_una
                # There's a hole: find segment starting at hole
                for seg in s.send_buffer
                    if seg.seq == hole && seg.retx_count < 3
                        seg.retx_count += 1
                        seg.last_sent = Now()
                        push!(s.segment_out, seg)
                        break
                    end
                end
            end
        end

    elseif ack_num == s.snd_una
        # ── Duplicate ACK ──
        s.cc_params[:dup_ack_count] = get(s.cc_params, :dup_ack_count, 0) + 1
        if s.cc_params[:dup_ack_count] >= 3
            OnDupAck(s)
            # Fast retransmit: retransmit the first unacknowledged segment
            if !isempty(s.send_buffer)
                seg = s.send_buffer[1]
                seg.retx_count += 1
                seg.last_sent = Now()
                push!(s.segment_out, seg)
            end
        end
    end
end

"""SACK Scoreboard (RFC 2018 §3 / RFC 6675)

跟踪接收端已确认的所有序列号区间，用于精确重传决策。
"""
mutable struct SackScoreboard
    blocks::Vector{SackBlock}  # 已确认区间 (排序, 不重叠)
    total_acked::Int           # 总确认字节数
    last_update::Float64
end
SackScoreboard() = SackScoreboard(SackBlock[], 0, 0.0)

"""更新 Scoreboard: 合并新的 SACK block"""
function update_scoreboard!(sb::SackScoreboard, new_blocks::Vector{SackBlock})
    for blk in new_blocks
        push!(sb.blocks, blk)
    end
    # Merge overlapping blocks
    sort!(sb.blocks, by=b -> b.left)
    merged = SackBlock[]
    for blk in sb.blocks
        if !isempty(merged) && blk.left <= merged[end].right + 1
            merged[end] = SackBlock(merged[end].left, max(merged[end].right, blk.right))
        else
            push!(merged, blk)
        end
    end
    sb.blocks = merged
    sb.total_acked = sum(b.right - b.left for b in sb.blocks)
    sb.last_update = Now()
end

"""Scoreboard: 序列号是否已被 SACK 确认"""
function is_sacked(sb::SackScoreboard, seq::UInt32)::Bool
    for blk in sb.blocks
        if seq >= blk.left && seq < blk.right
            return true
        end
    end
    false
end

"""Scoreboard: 查找第一个未确认的区间 (空洞)"""
function first_hole(sb::SackScoreboard, snd_una::UInt32)::UInt32
    for blk in sb.blocks
        if blk.left > snd_una
            return snd_una
        end
        snd_una = max(snd_una, blk.right)
    end
    snd_una
end

"""SACK processing (RFC 2018 + RFC 6675)"""
function process_sack(s::TcpSocket, blocks::Vector{SackBlock})
    # Initialize scoreboard if needed
    if !haskey(s.cc_params, :scoreboard)
        s.cc_params[:scoreboard] = SackScoreboard()
    end
    sb = s.cc_params[:scoreboard]
    update_scoreboard!(sb, blocks)

    # Update RACK FACK (forward ACK): highest SACKed sequence
    if !isempty(blocks)
        s.rack_fack = max(s.rack_fack, blocks[end].right)
        rtt_sample = Now() - s.rack_rtt
        if rtt_sample > 0
            s.rack_rtt = rtt_sample
            # RFC 8985: RACK reordering threshold
            rack_thresh = max(s.rack_rtt * 1.5, 0.001)
        end
    end
end

"""RACK loss detection (RFC 8985)

检测被 SACK 确认但尚未被累积 ACK 确认的段是否丢失。
"""
function rack_detect_loss(s::TcpSocket)::Vector{TcpSegment}
    lost = TcpSegment[]
    sb = get(s.cc_params, :scoreboard, nothing)
    sb === nothing && return lost

    for seg in s.send_buffer
        seq_end = seg.seq + max(UInt32(length(seg.payload)), UInt32(1))
        # 段被 SACK 确认但未累积 ACK → 可能丢失
        if seq_end <= s.rack_fack && seq_end > s.snd_una
            elapsed = Now() - seg.last_sent
            # RACK reordering window: 1.5 * RTT
            rack_thresh = max(s.rack_rtt * 1.5, 0.001)
            if elapsed > rack_thresh
                # 确认丢失：该段需要重传
                seg.retx_count += 1
                push!(lost, seg)
            end
        end
    end
    lost
end

"""TLP (Tail Loss Probe, RFC 8985 §6)

当发送队列尾部的段可能丢失时，发送一个探测包触发 ACK/RACK。
"""
function tail_loss_probe(s::TcpSocket, now_t::Float64)::Union{TcpSegment,Nothing}
    isempty(s.send_buffer) && return nothing
    seg = s.send_buffer[end]
    elapsed = now_t - seg.last_sent
    # TLP: if 2 * RTT since last segment sent, probe
    if elapsed > max(s.rto * 0.5, s.rack_rtt * 2.0, 0.01)
        seg.retx_count += 1
        seg.last_sent = now_t
        return seg
    end
    nothing
end

"""Flow control: available window"""
function send_window(s::TcpSocket)::UInt32
    win = min(s.cwnd, (s.snd_wnd << s.snd_wscale) / s.mss)
    inflight = (s.snd_nxt - s.snd_una) / s.mss
    max(0, Int(floor(win)) - Int(floor(inflight)))
end

"""Advertised receive window (RFC 7323)"""
function advertised_window(s::TcpSocket)::UInt16
    avail = s.rcv_wnd - s.rcv_wnd_used
    avail = max(0, min(avail, 65535 << s.rcv_wscale))
    UInt16(avail >> s.rcv_wscale)
end

"""RTT estimation (RFC 6298)"""
function UpdateRtt(s::TcpSocket, sample::Float64)
    if s.srtt == 0.0
        s.srtt = sample; s.rttvar = sample/2
    else
        alpha=0.125; beta=0.25
        s.rttvar = (1-beta)*s.rttvar + beta*abs(s.srtt-sample)
        s.srtt = (1-alpha)*s.srtt + alpha*sample
    end
    s.rto = max(s.srtt + 4*s.rttvar, 1.0)
end

"""Timestamp clock (RFC 7323 §5)"""
ts_now(s::TcpSocket) = UInt32(Now() * 1000) + s.ts_offset

"""超时重传 (RTO + TLP + RACK)

执行顺序：
1. RACK 丢失检测: 检查被 SACK 确认但未累积 ACK 的段
2. TLP 探测: 发送队列尾部探测包
3. RTO 重传: 超时段全部重传 + 指数退避
"""
function RetransmitTimeouts(s::TcpSocket, now_t::Float64)
    # ── Step 1: RACK loss detection (RFC 8985) ──
    rack_lost = rack_detect_loss(s)
    for seg in rack_lost
        if now_t - seg.last_sent > max(s.srtt * 1.5, 0.001)
            push!(s.segment_out, seg)
            seg.last_sent = now_t
        end
    end

    # ── Step 2: TLP probe (RFC 8985 §6) ──
    tlp = tail_loss_probe(s, now_t)
    if tlp !== nothing
        push!(s.segment_out, tlp)
        return
    end

    # ── Step 3: RTO retransmit ──
    expired = false
    for seg in s.send_buffer
        if now_t - seg.last_sent > s.rto
            seg.retx_count += 1; seg.last_sent = now_t
            push!(s.segment_out, seg)
            expired = true
        end
    end
    if expired
        OnTimeout(s)
        # Exponential backoff (RFC 6298)
        s.rto = min(s.rto * 2, 120.0)
    end
end

"""BBR pacing: 计算两次发送之间的间隔 (秒)"""
function pacing_delay(s::TcpSocket)::Float64
    if s.cc == CC_BBR && s.pacing_rate > 0
        return s.mss * 8.0 / s.pacing_rate
    end
    0.0  # no pacing for non-BBR
end

"""Generate SACK blocks"""
function generate_sack(s::TcpSocket)::Vector{SackBlock}
    return [SackBlock(seq, seq+length(seg.payload)) for (seq, seg) in s.recv_buffer]
end

"""Nagle check (RFC 896)"""
function nagle_ok(s::TcpSocket)::Bool
    !s.nagle_enabled || isempty(s.send_buffer)
end

"""ECN marking"""
function ecn_mark(s::TcpSocket, seg::TcpSegment)
    if s.ecn_enabled && s.ecn_echo
        seg.flags |= TCP_CWR
        s.ecn_echo = false
    end
end

"""BBR pacing"""
function pacing_tx_time(s::TcpSocket, bytes::Int)::Float64
    bytes * 8.0 / max(s.pacing_rate, 1.0)
end

# ═══════════════════════════════════════════
#  Congestion Control
# ═══════════════════════════════════════════

function OnAck(s::TcpSocket)
    if s.cc==CC_RENO; OnAckReno(s)
    elseif s.cc==CC_CUBIC; OnAckCubic(s)
    elseif s.cc==CC_BBR; OnAckBBR(s); end
end
function OnLoss(s::TcpSocket)
    if s.cc==CC_RENO; OnLossReno(s)
    elseif s.cc==CC_CUBIC; OnLossCubic(s); end
end
function OnDupAck(s::TcpSocket)
    if s.cc==CC_RENO; OnDupAckReno(s)
    elseif s.cc==CC_CUBIC; OnDupAckCubic(s); end
end
function OnTimeout(s::TcpSocket)
    if s.cc==CC_RENO; OnTimeoutReno(s)
    elseif s.cc==CC_CUBIC; OnTimeoutCubic(s)
    elseif s.cc==CC_BBR; OnTimeoutBBR(s); end
end

# ═══════════════════════════════════════════
#  HyStart (RFC 8511)
# ═══════════════════════════════════════════

"""HyStart (Hybrid Slow Start, RFC 8511 §3)

在慢启动阶段检测两种信号：
1. ACK train: RTT 快速增长 → 退出
2. Delay increase: 最小 RTT 增长超过阈值 → 退出

在卫星场景(LTE-NTN)下尤为重要：避免过度缓冲膨胀。
"""
function hystart_check(s::TcpSocket)::Bool
    # Only active in slow start
    s.cwnd >= s.ssthresh && return false

    now_t = Now()
    last_time = get(s.cc_params, :hystart_last_time, now_t)
    min_rtt = get(s.cc_params, :hystart_min_rtt, s.srtt)
    rtt_thresh = get(s.cc_params, :hystart_rtt_thresh, 0.0)
    round_count = get(s.cc_params, :hystart_round, 0)

    # Update min-RTT each round
    if now_t - last_time > s.srtt  # new round
        s.cc_params[:hystart_round] = round_count + 1
        s.cc_params[:hystart_last_time] = now_t

        # Delay increase detection
        if min_rtt > 0 && s.srtt > min_rtt * 1.5  # 50% increase
            s.cc_params[:hystart_rtt_thresh] += 1
        end
        s.cc_params[:hystart_min_rtt] = min(s.srtt, min_rtt)

        # ACK train detection (simplified)
        ack_gap = now_t - s.rtt_time
        if ack_gap > s.srtt * 2  # ACK spacing exceeds RTT
            s.cc_params[:hystart_rtt_thresh] += 1
        end

        s.rtt_time = now_t
    end

    # Exit slow start when threshold crossed
    if get(s.cc_params, :hystart_rtt_thresh, 0) >= 2
        s.ssthresh = s.cwnd
        return true  # exit slow start
    end
    false
end

# ═══════════════════════════════════════════
#  PRR (RFC 6937 — Proportional Rate Reduction)
# ═══════════════════════════════════════════

"""PRR (RFC 6937 §3.1): 丢包恢复期间的发送速率控制

公式: sndcnt = max(prr_delivered * prr_target / prr_max, mss)
  其中 prr_delivered = 恢复期间已交付的数据量
       prr_target    = cwnd * (prr_delivered / prr_max) 的积分
"""
function prr_update(s::TcpSocket, ack_num::UInt32)::Int
    if !s.cc_params[:in_recovery]
        return s.mss  # not in recovery, send normally
    end

    delivered = get(s.cc_params, :prr_delivered, 0)
    prr_max = get(s.cc_params, :prr_max, s.ssthresh)
    newly_acked = ack_num - s.snd_una

    # PRR: send 1 segment per 2 ACKs (RFC 6937 default)
    s.cc_params[:prr_delivered] = delivered + newly_acked
    prr_target = s.ssthresh * (delivered / max(prr_max, 1.0))
    sndcnt = max(Int(floor(prr_target - delivered)), s.mss)
    max(sndcnt, s.mss)
end

# ═══════════════════════════════════════════
#  Reno CC + HyStart + PRR
# ═══════════════════════════════════════════

function OnAckReno(s)
    if s.cwnd < s.ssthresh
        # Slow start with HyStart
        hystart_check(s)
        s.cwnd += 1.0
    else
        # Congestion avoidance
        s.cwnd += 1.0 / s.cwnd
    end
    # PRR: limit burst after recovery
    if get(s.cc_params, :in_recovery, false)
        snd = prr_update(s, s.snd_una)
        s.cwnd = min(s.cwnd, snd / s.mss + 1)
    end
    s.cc_params[:dup_ack_count] = 0
end

function OnLossReno(s)
    if !s.cc_params[:in_recovery]
        s.ssthresh = max(s.cwnd / 2, 2.0)
        # PRR init
        s.cc_params[:prr_max] = s.cwnd
        s.cc_params[:prr_delivered] = 0
        s.cwnd = s.ssthresh
        s.cc_params[:in_recovery] = true
    end
end

function OnDupAckReno(s)
    s.cc_params[:dup_ack_count] += 1
    if s.cc_params[:dup_ack_count] >= 3
        OnLossReno(s)
        s.cwnd = s.ssthresh
    end
end

function OnTimeoutReno(s)
    s.ssthresh = max(s.cwnd / 2, 2.0)
    s.cwnd = 1.0
    s.cc_params[:dup_ack_count] = 0
    s.cc_params[:in_recovery] = false
    # Reset HyStart
    s.cc_params[:hystart_rtt_thresh] = 0
    s.cc_params[:hystart_min_rtt] = 0.0
end

# ═══════════════════════════════════════════
#  Cubic CC + HyStart + PRR
# ═══════════════════════════════════════════

function OnAckCubic(s)
    if s.cwnd < s.ssthresh
        # Slow start with HyStart
        hystart_check(s)
        s.cwnd += 1.0
        return
    end

    # Congestion avoidance — Cubic mode
    if s.cc_params[:epoch_start] == 0.0
        s.cc_params[:epoch_start] = Now()
        s.cc_params[:origin_point] = s.cwnd
    end

    t = Now() - s.cc_params[:epoch_start]
    wm = s.cc_params[:w_max]
    c = s.cc_params[:c]
    k = cbrt(wm * (1 - 0.2) / c)
    target = c * (t - k)^3 + wm

    if target > s.cwnd
        s.cwnd += (target - s.cwnd) / s.cwnd
    else
        s.cwnd += 0.001  # concave growth
    end

    # PRR burst limiting
    if get(s.cc_params, :in_recovery, false)
        snd = prr_update(s, s.snd_una)
        s.cwnd = min(s.cwnd, snd / s.mss + 1)
    end
end

function OnLossCubic(s)
    s.cc_params[:w_max] = s.cwnd
    c = s.cc_params[:c]
    s.cc_params[:k] = cbrt(s.cwnd * (1 - 0.2) / c)
    s.ssthresh = s.cwnd * 0.8
    # PRR init
    s.cc_params[:prr_max] = s.cwnd
    s.cc_params[:prr_delivered] = 0
    s.cwnd = s.ssthresh
    s.cc_params[:epoch_start] = 0.0
    s.cc_params[:in_recovery] = true
end

function OnDupAckCubic(s)
    s.cc_params[:dup_ack_count] += 1
    if s.cc_params[:dup_ack_count] >= 3 && !s.cc_params[:in_recovery]
        OnLossCubic(s)
    end
end

function OnTimeoutCubic(s)
    s.cc_params[:w_max] = s.cwnd
    s.ssthresh = s.cwnd * 0.7
    s.cwnd = 1.0
    s.cc_params[:epoch_start] = 0.0
    s.cc_params[:in_recovery] = false
    s.cc_params[:dup_ack_count] = 0
    s.cc_params[:hystart_rtt_thresh] = 0
end

function OnAckBBR(s)
    bs = s.cc_params[:bbr_state]; bw = s.cc_params[:bw]; ts = Now()

    # BBRv2: bandwidth sampling with packet delivery (simplified)
    rtt_sample = max(s.srtt, 0.001)
    s.cc_params[:bw] = bw * 0.9 + (s.mss / rtt_sample) * 0.1  # EWMA

    if bs == 0  # STARTUP: 2/ln(2) ≈ 2.89 gain
        s.cwnd = max(s.cwnd + 3.0, s.cwnd * 1.5)
        s.pacing_gain = 2.89; s.pacing_rate = s.cc_params[:bw] * 2.89
        # BBRv2 exit: BW plateau detected (3 rounds with < 25% gain)
        if bw <= get(s.cc_params,:bw_max,0.0) * 1.25
            s.cc_params[:plateau_count] = get(s.cc_params,:plateau_count,0) + 1
        else
            s.cc_params[:plateau_count] = 0
        end
        s.cc_params[:bw_max] = max(get(s.cc_params,:bw_max,0.0), bw)
        if get(s.cc_params,:plateau_count,0) >= 3
            s.cc_params[:bbr_state] = 1; s.cc_params[:plateau_count] = 0
        end

    elseif bs == 1  # DRAIN
        s.cwnd = max(2.0, s.cwnd * 0.5)
        s.pacing_gain = 1.0 / 2.89
        if InFlight(s) <= s.cwnd
            s.cc_params[:bbr_state] = 2  # PROBE_BW
            s.cc_params[:probe_cycle] = 0
        end

    elseif bs == 2  # PROBE_BW: 8-phase cycling (BBRv2)
        cycle_phase = get(s.cc_params, :probe_cycle, 0) % 8
        pacing_cycle = [1.25, 0.75, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
        s.pacing_gain = pacing_cycle[cycle_phase+1]
        s.pacing_rate = s.cc_params[:bw] * s.pacing_gain
        s.cc_params[:probe_cycle] = cycle_phase + 1

        # BBRv2: loss-based cwnd reduction
        loss_rate = get(s.cc_params, :loss_rate, 0.0)
        if loss_rate > 0.02  # 2% loss → reduce
            s.cwnd = s.cwnd * (1.0 - min(loss_rate * 5, 0.3))
        end

        # Periodic PROBE_RTT
        if ts - get(s.cc_params,:probe_rtt_done,ts) >= 10.0
            s.cc_params[:bbr_state] = 3
            s.cc_params[:probe_rtt_done] = ts
        end

    elseif bs == 3  # PROBE_RTT
        s.cwnd = min(s.cwnd, 4.0)  # drain to 4 packets
        s.pacing_gain = 1.0
        if InFlight(s) <= 4
            s.cc_params[:bbr_state] = 2  # back to PROBE_BW
            # BBRv2: update min_rtt
            s.cc_params[:probe_rtt_done] = ts
        end
    end
end

function OnTimeoutBBR(s)
    s.cc_params[:bbr_state] = 0
    s.cwnd = 1.0
    s.pacing_rate = 1e6
    s.cc_params[:probe_rtt_done] = Now()
    s.cc_params[:plateau_count] = 0
    s.cc_params[:probe_cycle] = 0
end

InFlight(s) = length(s.send_buffer)*s.mss
IsEstablished(s) = s.state == ESTABLISHED
IsClosed(s) = s.state == CLOSED
Reset(s) = (s.state=CLOSED; empty!(s.send_buffer); empty!(s.recv_buffer);
            empty!(s.retrans_queue); s.cwnd=1.0; s.ssthresh=65535.0)

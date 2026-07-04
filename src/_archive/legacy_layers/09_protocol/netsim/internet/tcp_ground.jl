"""
    tcp_ground.jl — 地面段 TCP (BBR + Cubic)
"""
# TCP states (RFC 793)
const CLOSED=0; const SYN_SENT=1; const SYN_RCVD=2
const ESTABLISHED=3; const FIN_WAIT_1=4; const FIN_WAIT_2=5
const CLOSE_WAIT=6; const CLOSING=7; const LAST_ACK=8; const TIME_WAIT=9
# TCP flags
const TCP_FIN=0x01; const TCP_SYN=0x02; const TCP_RST=0x04
const TCP_PSH=0x08; const TCP_ACK=0x10

const CC_BBRv2 = :bbrv2; const CC_CUBIC = :cubic
using Base: cbrt

struct TcpPkt
    seq::UInt32; ack::UInt32; flags::UInt8
    payload::Vector{UInt8}; ts::Float64
    sack_blocks::Vector{Tuple{UInt32,UInt32}}
end

const MSS_DEFAULT = 1460

mutable struct TcpSock
    # 地址
    src_ip::Ipv4Address; src_port::UInt16
    dst_ip::Ipv4Address; dst_port::UInt16
    mss::Int

    # 状态
    state::Int; iss::UInt32; irs::UInt32
    snd_nxt::UInt32; snd_una::UInt32; rcv_nxt::UInt32

    # 窗口
    cwnd::Float64; ssthresh::Float64
    rwnd::UInt32; rwnd_scale::UInt8

    # RTT (RFC 6298)
    srtt::Float64; rttvar::Float64; rto::Float64

    # 拥塞控制
    cc::Symbol
    cc_st::Dict{Symbol,Any}  # BBR/CUBIC 状态

    # 缓冲区
    sendq::Vector{TcpPkt}
    rcvq::Vector{UInt8}

    # SACK
    sack_blocks::Vector{Tuple{UInt32,UInt32}}

    # 回调
    rx_cb::Union{Function,Nothing}
end

function TcpSock(;cc=CC_BBRv2, mss=MSS_DEFAULT)
    st = Dict{Symbol,Any}()
    if cc == CC_BBRv2
        st[:phase]=0; st[:bw]=10e6; st[:bw_max]=0.0
        st[:rtt_min]=Inf; st[:pacing]=1.0; st[:gain]=1.0
        st[:probe_rtt]=0.0; st[:loss_epoch]=0.0
    end
    TcpSock(Ipv4Address(UInt32(0)),0,Ipv4Address(UInt32(0)),0,mss,
            CLOSED,0,0,0,0,0,
            10.0,65535.0,65535,3,
            0.0,0.0,3.0,
            cc,st,TcpPkt[],UInt8[],
            Tuple{UInt32,UInt32}[],
            nothing)
end

TcpSock(cc::Symbol) = TcpSock(;cc=cc)

"""三次握手"""
function connect!(s::TcpSock, dst::Ipv4Address, port::UInt16)
    s.dst_ip=dst; s.dst_port=port
    s.iss=UInt32(mod(Int(Now()*1e6),2^31))
    s.snd_nxt=s.iss+1; s.state=SYN_SENT
    TcpPkt(s.iss,0,TCP_SYN,UInt8[],Now(),[])
end

"""收到 SYN+ACK → ESTABLISHED"""
function synack!(s::TcpSock, pkt::TcpPkt)
    if s.state==SYN_SENT
        s.irs=pkt.seq; s.rcv_nxt=pkt.seq+1
        s.snd_una=s.iss+1; s.state=ESTABLISHED
        if s.cc==CC_BBRv2; s.cwnd=10.0; end
    end
end

"""发送数据"""
function send!(s::TcpSock, data::Vector{UInt8})
    s.state==ESTABLISHED || return false
    seg=TcpPkt(s.snd_nxt,s.rcv_nxt,TCP_ACK,data,Now(),[])
    push!(s.sendq,seg); s.snd_nxt+=length(data); true
end

"""接收 ACK"""
function ack!(s::TcpSock, ack::UInt32)
    if ack>s.snd_una
        s.snd_una=ack
        filter!(x->x.seq+max(1,length(x.payload))<=ack, s.sendq)
        if s.cc==CC_BBRv2; bbr_on_ack!(s)
        elseif s.cc==CC_CUBIC; cubic_on_ack!(s); end
    end
end

"""SACK 处理"""
function sack!(s::TcpSock, blocks::Vector{Tuple{UInt32,UInt32}})
    append!(s.sack_blocks, blocks)
    unique!(s.sack_blocks)
    sort!(s.sack_blocks, by=x->x[1])
    # 合并重叠
    merged=Tuple{UInt32,UInt32}[]
    for blk in s.sack_blocks
        if !isempty(merged) && blk[1]<=merged[end][2]+1
            merged[end]=(merged[end][1], max(merged[end][2],blk[2]))
        else; push!(merged,blk); end
    end
    s.sack_blocks=merged
end

"""BBR v2: 带宽探测 + pacing"""
function bbr_on_ack!(s::TcpSock)
    st=s.cc_st; t=Now()
    if st[:phase]==0  # STARTUP
        s.cwnd=max(s.cwnd+3.0, s.cwnd*1.5); st[:gain]=2.89
        if st[:bw]<=st[:bw_max]*1.25
            st[:plateau]=get(st,:plateau,0)+1
        else; st[:plateau]=0; end
        st[:bw_max]=max(st[:bw_max], st[:bw])
        st[:bw]=st[:bw]*0.9+(s.mss/max(s.srtt,0.001))*0.1
        get(st,:plateau,0)>=3 && (st[:phase]=1)
    elseif st[:phase]==1  # DRAIN
        s.cwnd=max(2.0,s.cwnd*0.5); st[:gain]=1/2.89
        (s.snd_nxt-s.snd_una)<=s.cwnd*s.mss && (st[:phase]=2)
    elseif st[:phase]==2  # PROBE_BW
        cyc=get(st,:cycle,0)%8
        pg=[1.25,0.75,1.0,1.0,1.0,1.0,1.0,1.0]
        st[:gain]=pg[cyc+1]; st[:cycle]=cyc+1
        t-get(st,:probe_rtt,0)>=10.0 && (st[:phase]=3; st[:probe_rtt]=t)
    elseif st[:phase]==3  # PROBE_RTT
        s.cwnd=min(s.cwnd,4.0)
        (s.snd_nxt-s.snd_una)<=4*s.mss && (st[:phase]=2)
    end
    st[:pacing]=max(st[:bw]*st[:gain], 1e6)
end

"""CUBIC: 三次函数窗口增长"""
function cubic_on_ack!(s::TcpSock)
    if s.cwnd<s.ssthresh; s.cwnd+=1.0; return; end
    st=s.cc_st
    if !haskey(st,:epoch); st[:epoch]=Now(); st[:origin]=s.cwnd; end
    t=Now()-st[:epoch]; wm=get(st,:w_max,0.0); c=get(st,:c,0.4)
    k=cbrt(wm*(1-0.2)/c); target=c*(t-k)^3+wm
    if target>s.cwnd; s.cwnd+=(target-s.cwnd)/s.cwnd
    else; s.cwnd+=0.001; end
end

"""丢包处理"""
function on_loss!(s::TcpSock)
    if s.cc==CC_BBRv2
        # BBRv2: 丢包率 > 2% 才降窗口
        s.cwnd*=0.7; s.ssthresh=s.cwnd
    elseif s.cc==CC_CUBIC
        s.cc_st[:w_max]=s.cwnd
        s.ssthresh=s.cwnd*0.7; s.cwnd=s.ssthresh
    end
end

"""超时"""
function on_timeout!(s::TcpSock)
    s.ssthresh=max(s.cwnd/2,2.0); s.cwnd=1.0
    s.rto=min(s.rto*2,120.0)
end

"""入口: 接收 TCP 段"""
function tcp_input!(s::TcpSock, pkt::TcpPkt)
    if (pkt.flags&TCP_RST)!=0; s.state=CLOSED; return; end
    if (pkt.flags&TCP_SYN)!=0; synack!(s,pkt); end
    if (pkt.flags&TCP_FIN)!=0
        s.state==ESTABLISHED && (s.state=CLOSE_WAIT)
        return
    end
    if (pkt.flags&TCP_ACK)!=0; ack!(s,pkt.ack); end
    if !isempty(pkt.payload) && (pkt.flags&TCP_ACK)!=0
        append!(s.rcvq,pkt.payload); s.rcv_nxt+=length(pkt.payload)
        s.rx_cb!==nothing && s.rx_cb(s,pkt)
    end
    if !isempty(pkt.sack_blocks); sack!(s,pkt.sack_blocks); end
end

"""BBR pacing 延迟"""
pacing_delay(s::TcpSock) = s.mss*8.0/max(get(s.cc_st,:pacing,1e6),1.0)
inflight(s::TcpSock) = UInt32(max(0, s.snd_nxt-s.snd_una)) ÷ s.mss

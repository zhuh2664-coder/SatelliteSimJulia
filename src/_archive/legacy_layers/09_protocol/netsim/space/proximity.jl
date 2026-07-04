"""
    proximity.jl — CCSDS Proximity-1 空间链路协议

对标 CCSDS 211.0-B-6 / CCSDS 732.1-B-2。

Proximity-1 是专门为 ISL (Inter-Satellite Link) 设计的数据链路层协议。
特性：
1. 半双工/全双工通信
2. 可变帧长度
3. 序列号保护
4. 数据注入保护 (填充)
5. 支持 CCSDS 空间包封装

USLP (Unified Space Link Protocol) — CCSDS 732.1
统一 TM (遥测)、TC (遥控)、AOS、Proximity-1 四种链路协议。
"""
# 帧类型
const PROX_FRAME_DATA   = 0x01  # 数据帧
const PROX_FRAME_ACK    = 0x02  # 确认帧
const PROX_FRAME_CTRL   = 0x03  # 控制帧

# 操作模式
const PROX_MODE_DUPLEX      = 0  # 全双工
const PROX_MODE_HALF_DUPLEX = 1  # 半双工

# 辅助类型 (借UInt32模拟24位)
const UInt24 = UInt32

struct Proximity1Frame
    version::UInt8
    type::UInt8
    seq::UInt16
    length::UInt16
    data::Vector{UInt8}
end

"""
    Proximity1Link — Proximity-1 ISL 链路

模拟一条 ISL 链路的 Proximity-1 协议行为。
"""
mutable struct Proximity1Link
    src::UInt32
    dst::UInt32
    mode::Int              # 双工模式
    frame_seq::UInt16      # 帧序列号
    max_frame_size::Int

    # 链路状态
    is_active::Bool
    signal_quality::Float64  # 0.0-1.0

    # 统计
    tx_frames::Int
    rx_frames::Int
    lost_frames::Int
    bit_errors::Int
end

function Proximity1Link(src::UInt32, dst::UInt32; mode=PROX_MODE_DUPLEX, max_frame=8192)
    Proximity1Link(src, dst, mode, 0, max_frame,
                   true, 1.0, 0, 0, 0, 0)
end

"""
    encode_frame(link, data, frame_type) → Proximity1Frame

将数据封装为 Proximity-1 帧。
"""
function encode_frame(link::Proximity1Link, data::Vector{UInt8},
                      frame_type::UInt8=PROX_FRAME_DATA)
    link.frame_seq += 1
    frame = Proximity1Frame(0, frame_type, link.frame_seq,
                           UInt16(length(data)), data)

    # 模拟位错误
    if link.signal_quality < 1.0
        error_bits = Int(round(length(data) * 8 * (1 - link.signal_quality)))
        if error_bits > 0
            link.bit_errors += error_bits
            # 随机翻转位（简化）
            if rand() < 0.1  # 10% 概率帧损坏
                return nothing
            end
        end
    end

    link.tx_frames += 1
    return frame
end

"""
    receive_frame(link, frame) → Bool

接收 Proximity-1 帧。
"""
function receive_frame(link::Proximity1Link, frame::Proximity1Frame)::Bool
    if !link.is_active
        return false
    end
    link.rx_frames += 1
    return true
end

"""
    set_signal_quality(link, quality)

设置信号质量 (0.0-1.0)，用于模拟链路衰减。
"""
function set_signal_quality(link::Proximity1Link, quality::Float64)
    link.signal_quality = max(0.0, min(1.0, quality))
    nothing
end

"""
    USLPFrame — 统一空间链路协议帧

CCSDS 732.1-B-2 定义的统一帧格式，
兼容 TM/TC/AOS/Proximity-1 四种模式。
"""
struct USLPFrame
    version::UInt8
    spacecraft_id::UInt16
    virtual_channel::UInt8
    frame_length::UInt16
    frame_seq::UInt24
    data::Vector{UInt8}
    # OCF (操作控制域)
    has_ocf::Bool
    # FECF (帧错误控制)
    has_fecf::Bool
end


"""
    uslp.jl — CCSDS Unified Space Link Protocol (CCSDS 732.1-B-2)

USLP unifies TM (Telemetry), TC (Telecommand), AOS (Advanced Orbiting Systems),
and Proximity-1 into a single protocol. It provides:

  - Frame-level error control (CRC)
  - Virtual Channels (VC): multiplexing up to 8 channels
  - Master Channel (MC): the physical link
  - Frame types: Data, Control, Idle
  - Frame segmentation and reassembly
  - Communication Link Control (CLCW, CLC)
"""
# Frame types
const USLP_DATA_FRAME = 0x01
const USLP_CTRL_FRAME = 0x02
const USLP_IDLE_FRAME = 0x03

# Operating modes
const USLP_MODE_PACKET = 0    # Packet-level (VCA)
const USLP_MODE_BITSTREAM = 1 # Bitstream
const USLP_MODE_VC = 2        # Virtual Channel Access

# Frame header
struct UslpFrameHeader
    version::UInt8        # 2 bits
    spacecraft_id::UInt16 # 10 bits
    vcid::UInt8           # 3 bits: Virtual Channel ID (0-7)
    frame_type::UInt8     # 2 bits: 01=data, 10=ctrl, 11=idle
    frame_length::UInt16  # frame data length in bytes
    seq::UInt16           # frame sequence number
end

mutable struct UslpFrame
    header::UslpFrameHeader
    data::Vector{UInt8}
    has_fecf::Bool        # Frame Error Control Field (CRC)
    fecf::UInt16          # CRC-16
    has_ocf::Bool         # Operational Control Field
    ocf::UInt32           # OCF data
end

function UslpFrame(scid::UInt16, vcid::UInt8, data::Vector{UInt8};
                    frame_type=USLP_DATA_FRAME, crc=true)
    hdr = UslpFrameHeader(0, scid, vcid, frame_type, UInt16(length(data)), 0)
    UslpFrame(hdr, data, crc, 0, false, 0)
end

"""Encode USLP frame to bytes"""
function encode(frame::UslpFrame)::Vector{UInt8}
    buf = UInt8[]
    # Transfer Frame Primary Header (6 bytes)
    w1 = (UInt16(frame.header.spacecraft_id) << 6) |
         (UInt16(frame.header.vcid) << 3) |
         (UInt16(frame.header.frame_type) << 1)
    push!(buf, UInt8(w1 >> 8), UInt8(w1 & 0xff))

    w2 = frame.header.frame_length
    push!(buf, UInt8(w2 >> 8), UInt8(w2 & 0xff))

    # Frame sequence number
    push!(buf, UInt8(frame.header.seq >> 8), UInt8(frame.header.seq & 0xff))

    # Frame data
    append!(buf, frame.data)

    # FECF (CRC-16 CCITT)
    if frame.has_fecf
        crc = compute_crc16(buf)
        push!(buf, UInt8(crc >> 8), UInt8(crc & 0xff))
    end
    buf
end

"""CRC-16-CCITT (x¹⁶ + x¹² + x⁵ + 1)"""
function compute_crc16(data::Vector{UInt8})::UInt16
    crc = UInt16(0xffff)
    for byte in data
        crc ⊻= UInt16(byte) << 8
        for _ in 1:8
            crc = (crc & 0x8000) != 0 ? (crc << 1) ⊻ 0x1021 : crc << 1
        end
    end
    crc
end

# ── Master Channel (MC) ──
mutable struct MasterChannel
    scid::UInt16          # Spacecraft ID
    vcs::Vector{VirtualChannel}  # 0-7 Virtual Channels
    tx_frame_count::UInt64
    rx_frame_count::UInt64
    active::Bool
end

function MasterChannel(scid::UInt16; n_vc::Int=4)
    vcs = [VirtualChannel(UInt8(i)) for i in 0:n_vc-1]
    MasterChannel(scid, vcs, 0, 0, true)
end

function transmit_frame(mc::MasterChannel, vcid::UInt8, data::Vector{UInt8})
    seq = UInt16(mc.tx_frame_count & 0xffff)
    hdr = UslpFrameHeader(0, mc.scid, vcid, USLP_DATA_FRAME, UInt16(length(data)), seq)
    frame = UslpFrame(hdr, data, true, 0, false, 0)
    mc.tx_frame_count += 1
    encode(frame)
end

function receive_frame(mc::MasterChannel, frame::UslpFrame)
    if frame.has_fecf
        computed = compute_crc16(encode(frame)[1:end-2])
        computed != frame.fecf && return false
    end
    vcid = frame.header.vcid
    if vcid < length(mc.vcs)
        # Extract Space Packets from frame data
        mc.rx_frame_count += 1
        return true
    end
    false
end

# ── Communication Link Control ──
struct Clcw
    status::UInt8         # 0=OK, 1=fault
    vcid::UInt8           # affected VC
    rx_count::UInt32      # received frame count
    error_count::UInt16   # error count
end

struct CommunicationLinkControl
    clcw::Clcw
    timestamp::Float64
end

# ── USLP Frame Segmentation ──
function segment_data(data::Vector{UInt8}, max_frame_size::Int)::Vector{Vector{UInt8}}
    segs = Vector{UInt8}[]
    i = 1
    while i <= length(data)
        end_idx = min(i + max_frame_size - 1, length(data))
        push!(segs, data[i:end_idx])
        i += max_frame_size
    end
    segs
end

function reassemble_frames(frames::Vector{UslpFrame})::Vector{UInt8}
    data = UInt8[]
    for f in frames
        append!(data, f.data)
    end
    data
end

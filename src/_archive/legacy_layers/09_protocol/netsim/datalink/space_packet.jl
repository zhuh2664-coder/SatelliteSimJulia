"""
    space_packet.jl — CCSDS Space Packet Protocol (CCSDS 133.0-B-2)

The Space Packet is the fundamental data unit in CCSDS networks.
Sits between the datalink layer (USLP frames) and the application layer.

Structure (Primary Header):
┌──────────────────────────────────────────────────────┐
│ Packet Version Number (3 bits)                       │
│ Packet Identification (13 bits):                     │
│   - Type (1: TC, 0: TM)                             │
│   - Secondary Header Flag (1 bit)                   │
│   - Application Process ID (11 bits)                │
│ Packet Sequence Control (14 bits):                  │
│   - Sequence Flags (2 bits)                         │
│   - Packet Sequence Count (14 bits)                 │
│ Packet Data Length (16 bits)                        │
└──────────────────────────────────────────────────────┘
"""
const SPACE_PACKET_VERSION = 0b000
const PKT_TYPE_TM = UInt8(0)  # Telemetry (space→ground)
const PKT_TYPE_TC = UInt8(1)  # Telecommand (ground→space)

struct SpacePacketHeader
    version::UInt8      # 3 bits
    type::UInt8         # 1 bit: 0=TM, 1=TC
    sec_header::UInt8   # 1 bit: secondary header flag
    apid::UInt16        # 11 bits: Application Process ID
    seq_flags::UInt8    # 2 bits: 00=continuation, 01=first, 10=last, 11=standalone
    seq::UInt16         # 14 bits: packet sequence count
    data_length::UInt16 # bytes of data - 1
end

function make_pkt_hdr(apid::UInt16, type::UInt8=PKT_TYPE_TM; seq=0)
    SpacePacketHeader(SPACE_PACKET_VERSION, type, 0, apid & 0x07ff,
                      0b11, UInt16(seq & 0x3fff), 0)
end

mutable struct SpacePacket
    header::SpacePacketHeader
    secondary_header::Vector{UInt8}
    data::Vector{UInt8}
end

function SpacePacket(apid::UInt16, data::Vector{UInt8}; type=PKT_TYPE_TM, seq=0)
    hdr = SpacePacketHeader(SPACE_PACKET_VERSION, type, 0, apid & 0x07ff,
                             0b11, UInt16(seq & 0x3fff), UInt16(length(data) - 1))
    SpacePacket(hdr, UInt8[], data)
end

"""Encode Space Packet to bytes (CCSDS 133.0-B-2 §4)"""
function encode(pkt::SpacePacket)::Vector{UInt8}
    buf = UInt8[]
    # Primary Header (6 bytes)
    word1 = (UInt16(pkt.header.version) << 13) |
            (UInt16(pkt.header.type) << 12) |
            (UInt16(pkt.header.sec_header) << 11) |
            pkt.header.apid
    push!(buf, UInt8(word1 >> 8), UInt8(word1 & 0xff))

    word2 = (UInt16(pkt.header.seq_flags) << 14) | pkt.header.seq
    push!(buf, UInt8(word2 >> 8), UInt8(word2 & 0xff))

    push!(buf, UInt8(pkt.header.data_length >> 8), UInt8(pkt.header.data_length & 0xff))

    # Data
    append!(buf, pkt.data)
    buf
end

# Virtual Channel: multiplexing multiple Space Packets onto one physical link
mutable struct VirtualChannel
    vcid::UInt8           # Virtual Channel ID (0-7)
    apid_map::Dict{UInt16, Vector{SpacePacket}}  # APID → packets
    tx_count::UInt64
    rx_count::UInt64
end

VirtualChannel(vcid) = VirtualChannel(vcid, Dict{UInt16, Vector{SpacePacket}}(), 0, 0)

function add_packet!(vc::VirtualChannel, pkt::SpacePacket)
    apid = pkt.header.apid
    push!(get!(vc.apid_map, apid, SpacePacket[]), pkt)
    vc.tx_count += 1
end

function get_packets(vc::VirtualChannel, apid::UInt16)::Vector{SpacePacket}
    pkts = get(vc.apid_map, apid, SpacePacket[])
    vc.apid_map[apid] = SpacePacket[]
    vc.rx_count += length(pkts)
    pkts
end

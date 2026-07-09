# PCAP writer (ns-3 style) — Ethernet encapsulation of raw bytes

export PcapWriter, open_pcap, write_pcap_packet!, close_pcap!

"""
    PcapWriter

Write packets to a classic libpcap file (linktype Ethernet) for Wireshark.
"""
mutable struct PcapWriter
    filename::String
    io::IO
    packet_count::Int
    closed::Bool
end

"""
    open_pcap(filename) -> PcapWriter

Create/overwrite a PCAP file and write the global header.
"""
function open_pcap(filename::AbstractString)
    io = open(filename, "w")
    write(io, htol(UInt32(0xa1b2c3d4)))  # magic
    write(io, htol(UInt16(2)))           # version major
    write(io, htol(UInt16(4)))           # version minor
    write(io, htol(Int32(0)))            # thiszone
    write(io, htol(UInt32(0)))           # sigfigs
    write(io, htol(UInt32(65535)))       # snaplen
    write(io, htol(UInt32(1)))           # LINKTYPE_ETHERNET
    return PcapWriter(String(filename), io, 0, false)
end

function _mac6(mac::UInt64)
    return UInt8[
        UInt8((mac >> 40) & 0xff),
        UInt8((mac >> 32) & 0xff),
        UInt8((mac >> 24) & 0xff),
        UInt8((mac >> 16) & 0xff),
        UInt8((mac >> 8) & 0xff),
        UInt8(mac & 0xff),
    ]
end

"""
    write_pcap_packet!(pcap, payload; t=0.0, src_mac=1, dst_mac=2, ethertype=0x0800)

Append one Ethernet frame containing `payload`.
"""
function write_pcap_packet!(
    pcap::PcapWriter,
    payload::AbstractVector{UInt8};
    t::Real=0.0,
    src_mac::UInt64=UInt64(1),
    dst_mac::UInt64=UInt64(2),
    ethertype::UInt16=UInt16(0x0800),
)
    pcap.closed && throw(ArgumentError("pcap already closed"))
    frame = UInt8[]
    append!(frame, _mac6(dst_mac))
    append!(frame, _mac6(src_mac))
    push!(frame, UInt8((ethertype >> 8) & 0xff))
    push!(frame, UInt8(ethertype & 0xff))
    append!(frame, payload)
    while length(frame) < 60
        push!(frame, 0x00)
    end

    ts = Float64(t)
    ts_sec = floor(Int, ts)
    ts_usec = clamp(floor(Int, (ts - ts_sec) * 1_000_000), 0, 999_999)
    incl = min(length(frame), 65535)

    write(pcap.io, htol(UInt32(ts_sec)))
    write(pcap.io, htol(UInt32(ts_usec)))
    write(pcap.io, htol(UInt32(incl)))
    write(pcap.io, htol(UInt32(incl)))
    write(pcap.io, frame[1:incl])
    pcap.packet_count += 1
    return pcap.packet_count
end

function write_pcap_packet!(pcap::PcapWriter, pkt::Packet; kwargs...)
    buf = IOBuffer()
    write(buf, htol(UInt32(pkt.id)))
    write(buf, htol(UInt32(pkt.src)))
    write(buf, htol(UInt32(pkt.dst)))
    write(buf, UInt8(pkt.protocol))
    write(buf, htol(UInt32(pkt.size)))
    return write_pcap_packet!(pcap, take!(buf); kwargs...)
end

function close_pcap!(pcap::PcapWriter)
    pcap.closed && return nothing
    close(pcap.io)
    pcap.closed = true
    return nothing
end

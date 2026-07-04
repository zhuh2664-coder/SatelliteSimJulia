"""
    PcapWriter — PCAP 文件写入

对标 ns-3 PcapHelper。
将仿真包写入 PCAP 格式，可用 Wireshark 分析。
"""
mutable struct PcapWriter
    filename::String
    io::IO
    packet_count::Int
end

"""
    OpenPcap(filename) → PcapWriter
打开 PCAP 文件，写入全局头部。
"""
function OpenPcap(filename::String)
    io = open(filename, "w")
    # PCAP 全局头部（24 字节）
    write(io, UInt32(0xa1b2c3d4))  # magic number
    write(io, UInt16(2))            # version major
    write(io, UInt16(4))            # version minor
    write(io, Int32(0))             # timezone offset
    write(io, UInt32(0))            # timestamp accuracy
    write(io, UInt32(65535))        # snapshot length
    write(io, UInt32(1))            # link type (Ethernet)
    return PcapWriter(filename, io, 0)
end

"""
    WritePacket(pcap, pkt, src_mac, dst_mac, time)
将仿真包写入 PCAP。
"""
function WritePacket(pcap::PcapWriter, pkt, src_mac::UInt64, dst_mac::UInt64, time::Float64)
    # PCAP 包头部（16 字节）
    ts_sec = floor(Int, time)
    ts_usec = floor(Int, (time - ts_sec) * 1_000_000)
    pkt_len = min(length(pkt.payload) + 14, 65535)  # 14 = 以太网头

    write(pcap.io, UInt32(ts_sec))
    write(pcap.io, UInt32(ts_usec))
    write(pcap.io, UInt32(pkt_len))
    write(pcap.io, UInt32(pkt_len))

    # 以太网头部（14 字节）
    write(pcap.io, UInt64(dst_mac))   # dst MAC
    write(pcap.io, UInt64(src_mac))   # src MAC (前6字节有效)
    write(pcap.io, UInt16(0x0800))    # EtherType = IPv4

    # 包载荷
    write(pcap.io, pkt.payload)

    pcap.packet_count += 1
    nothing
end

"""
    ClosePcap(pcap)
关闭 PCAP 文件。
"""
function ClosePcap(pcap::PcapWriter)
    close(pcap.io)
    nothing
end

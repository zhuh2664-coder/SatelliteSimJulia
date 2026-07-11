# UDP — lightweight datagram helpers for DES path experiments

export UdpHeader, UDP_HEADER_SIZE, udp_payload_bytes

const UDP_HEADER_SIZE = 8

struct UdpHeader
    src_port::UInt16
    dst_port::UInt16
    length::UInt16
end

function UdpHeader(src_port::Integer, dst_port::Integer, payload_len::Integer)
    payload_len >= 0 || throw(ArgumentError("payload_len must be non-negative"))
    total = UDP_HEADER_SIZE + Int(payload_len)
    total <= typemax(UInt16) || throw(ArgumentError("UDP datagram too large"))
    return UdpHeader(UInt16(src_port), UInt16(dst_port), UInt16(total))
end

"""Wire size of a UDP datagram with `payload_len` bytes of payload."""
udp_payload_bytes(payload_len::Integer) = UDP_HEADER_SIZE + Int(payload_len)

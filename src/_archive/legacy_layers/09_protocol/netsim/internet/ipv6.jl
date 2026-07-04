"""
    IPv6 地址和头部（占位）

对标 ns-3 Ipv6Address / Ipv6Header。
框架占位，待后续实现。
"""
struct Ipv6Address
    addr::NTuple{4, UInt32}
end

Ipv6Address() = Ipv6Address((0, 0, 0, 0))

function Ipv6Address(s::String)
    # 简化：只接受省略格式
    error("IPv6 address parsing not yet implemented")
end

Base.:(==)(a::Ipv6Address, b::Ipv6Address) = a.addr == b.addr

struct Ipv6Header
    src::Ipv6Address
    dst::Ipv6Address
    traffic_class::UInt8
    flow_label::UInt32
    payload_length::UInt16
    next_header::UInt8
    hop_limit::UInt8
end

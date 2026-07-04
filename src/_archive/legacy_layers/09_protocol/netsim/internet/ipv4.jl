"""
    IPv4 地址和头部

对标 ns-3 Ipv4Address / Ipv4Header
"""
struct Ipv4Address
    addr::UInt32  # 网络字节序

    Ipv4Address(a::UInt32) = new(a)
    Ipv4Address() = new(0x00000000)
end

# 点分十进制构造
function Ipv4Address(s::String)
    parts = parse.(UInt32, split(s, "."))
    @assert length(parts) == 4
    addr = (parts[1] << 24) | (parts[2] << 16) | (parts[3] << 8) | parts[4]
    Ipv4Address(addr)
end

# 广播地址
Ipv4Broadcast() = Ipv4Address(0xffffffff)

# 比较
Base.:(==)(a::Ipv4Address, b::Ipv4Address) = a.addr == b.addr
Base.hash(a::Ipv4Address, h::UInt64) = hash(a.addr, h)

# 打印
function Base.show(io::IO, a::Ipv4Address)
    print(io, "$((a.addr >> 24) & 0xff).$((a.addr >> 16) & 0xff).$((a.addr >> 8) & 0xff).$(a.addr & 0xff)")
end

# 子网掩码
struct Ipv4Mask
    mask::UInt32
    Ipv4Mask(mask::UInt32) = new(mask)
    Ipv4Mask(s::String) = new(Ipv4Address(s).addr)
end

Ipv4Mask(prefix::Int) = Ipv4Mask((0xffffffff << (32 - prefix)) & 0xffffffff)

function (m::Ipv4Mask)(addr::Ipv4Address)
    Ipv4Address(addr.addr & m.mask)
end

# IPv4 头部
mutable struct Ipv4Header
    src::Ipv4Address
    dst::Ipv4Address
    protocol::UInt8   # 1=ICMP, 6=TCP, 17=UDP
    ttl::UInt8
    total_length::UInt16
    identification::UInt16
    fragment_offset::UInt16
    flags::UInt8
    header_checksum::UInt16
end

Ipv4Header(src, dst, proto; ttl=64, len=20) = Ipv4Header(
    src, dst, proto, ttl, len, 0, 0, 0, 0)

# IPv4 接口
mutable struct Ipv4Interface
    address::Ipv4Address
    mask::Ipv4Mask
    device_idx::Int
    is_up::Bool
end

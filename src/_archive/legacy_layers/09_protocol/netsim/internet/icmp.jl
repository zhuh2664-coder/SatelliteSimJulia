"""
    ICMP — 互联网控制消息协议（基础实现）

对标 ns-3 Icmpv4L4Protocol。
当前支持 Echo (ping) 和 Destination Unreachable。
"""
const ICMP_ECHO = 8
const ICMP_ECHO_REPLY = 0
const ICMP_DEST_UNREACH = 3
const ICMP_TIME_EXCEEDED = 11

struct IcmpHeader
    type::UInt8
    code::UInt8
    checksum::UInt16
    rest::UInt32  # echo: id<<16 | seq
end

# 创建 ICMP Echo
function IcmpEcho(id::UInt16, seq::UInt16)
    IcmpHeader(ICMP_ECHO, 0, 0, (UInt32(id) << 16) | seq)
end

# 创建 ICMP Echo Reply
function IcmpEchoReply(echo::IcmpHeader)
    IcmpHeader(ICMP_ECHO_REPLY, 0, 0, echo.rest)
end

# 创建 Destination Unreachable
function IcmpDestUnreach(code::UInt8=0)
    IcmpHeader(ICMP_DEST_UNREACH, code, 0, 0)
end

# 创建 Time Exceeded
function IcmpTimeExceeded(code::UInt8=0)
    IcmpHeader(ICMP_TIME_EXCEEDED, code, 0, 0)
end

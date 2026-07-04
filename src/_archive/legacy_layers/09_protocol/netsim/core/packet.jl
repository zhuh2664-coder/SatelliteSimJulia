"""
    Packet — 数据包

ns-3 Packet 简化版。包含头部元数据 + 载荷。
"""
mutable struct Packet
    id::UInt64
    size::Int
    src::UInt32
    dst::UInt32
    protocol::UInt8
    ts_create::Float64
    ts_arrival::Float64
    ts_departure::Float64
    payload::Vector{UInt8}
    Packet(id, size, src, dst, proto=17) = new(id, size, src, dst, proto, 0.0, 0.0, 0.0, UInt8[])
end

# 工厂方法
function CreatePacket(size::Int, src::UInt32, dst::UInt32; protocol=17)
    global _pkt_counter
    _pkt_counter += 1
    Packet(_pkt_counter, size, src, dst, protocol)
end
_pkt_counter = UInt64(0)

# 获取下一个包 ID（线程安全）
function next_pkt_id!()
    global _pkt_counter
    _pkt_counter += 1
    return _pkt_counter
end

# 复制包
function clone(p::Packet)
    Packet(p.id, p.size, p.src, p.dst, p.protocol)
end

# 设置时间戳
function timestamp!(p::Packet, t::Float64)
    p.ts_create = t
    p
end

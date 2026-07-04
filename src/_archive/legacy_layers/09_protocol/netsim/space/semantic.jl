"""
    semantic.jl — 语义寻址 (Satellite Semantic Addressing)

将卫星的轨道位置嵌入 IPv6 地址，实现"自路由"。
基于 IETF draft-lhan-satellite-semantic-addressing。

地址结构 (128-bit IPv6):
┌────────────────────────────────────────────────────────────────┐
│  Owner (16) │ Shell (8) │ Plane (8) │ Position (8) │ IID (88) │
└────────────────────────────────────────────────────────────────┘

- Owner: 运营商 ID (SpaceX=1, OneWeb=2, Iridium=3...)
- Shell: 壳层 ID (Starlink 有 3 个壳层)
- Plane: 轨道面 ID (0-71 for Starlink)
- Position: 面内位置 ID (0-21 for Starlink)
- IID: 接口标识符 (链路端口号)

语义路由：给定目的地址，直接从地址中提取 (shell, plane, position)
计算几何最短路径，不需要路由协议收敛。
"""
struct SemanticAddress
    owner::UInt16
    shell::UInt8
    plane::UInt8
    position::UInt8
    iid::UInt64
end

# 默认构造函数
SemanticAddress(owner, shell, plane, position; iid=0) =
    SemanticAddress(owner, shell, plane, position, iid)

# 从 UInt128 解析
function SemanticAddress(raw::UInt128)
    owner = UInt16((raw >> 112) & 0xffff)
    shell = UInt8((raw >> 104) & 0xff)
    plane = UInt8((raw >> 96) & 0xff)
    position = UInt8((raw >> 88) & 0xff)
    iid = UInt64(raw & 0xffffffffffffff)
    SemanticAddress(owner, shell, plane, position, iid)
end

# 编码为 UInt128
function encode(addr::SemanticAddress)::UInt128
    (UInt128(addr.owner) << 112) |
    (UInt128(addr.shell) << 104) |
    (UInt128(addr.plane) << 96) |
    (UInt128(addr.position) << 88) |
    UInt128(addr.iid)
end

# 编码为 IPv6 字符串
function to_ipv6(addr::SemanticAddress)::String
    raw = encode(addr)
    join([string((raw >> (112 - i*16)) & 0xffff, base=16) for i in 0:7], ":")
end

# 从轨道参数构造语义地址
function from_orbit_params(owner::UInt16, shell::UInt8,
                           plane::UInt8, position::UInt8)
    SemanticAddress(owner, shell, plane, position, 0)
end

# 距离度量
function orbital_distance(a::SemanticAddress, b::SemanticAddress)::Int
    if a.shell != b.shell
        # 跨壳层: 基础代价 256 + 轨道面差
        d_plane = abs(Int(a.plane) - Int(b.plane))
        d_plane = min(d_plane, 256 - d_plane)
        return 256 + d_plane
    end
    d_plane = abs(Int(a.plane) - Int(b.plane))
    d_pos = abs(Int(a.position) - Int(b.position))
    d_plane = min(d_plane, 256 - d_plane)
    d_pos = min(d_pos, 256 - d_pos)
    d_plane + d_pos
end

# 判断是否邻居 (同一轨道面相邻，或相邻轨道面同一位置)
function is_neighbor(a::SemanticAddress, b::SemanticAddress)::Bool
    a.shell == b.shell || return false
    d_plane = abs(Int(a.plane) - Int(b.plane))
    d_pos = abs(Int(a.position) - Int(b.position))
    # 面内邻居 (plane 相同, position 差 1)
    if d_plane == 0 && d_pos == 1
        return true
    end
    # 面间邻居 (plane 差 1, position 相同)
    if d_plane == 1 && d_pos == 0
        return true
    end
    return false
end

# 打印
Base.show(io::IO, a::SemanticAddress) = print(io, "Semantic($(a.owner).$(a.shell).$(a.plane).$(a.position))")

"""
    DHCP — 动态主机配置协议（占位）

对标 ns-3 DhcpClient / DhcpServer。
当前为框架占位，待实现。
"""
mutable struct DhcpServer
    pool_start::Ipv4Address
    pool_end::Ipv4Address
    subnet_mask::Ipv4Mask
    gateway::Ipv4Address
    leases::Dict{UInt32, Ipv4Address}  # node_id → ip
end

function DhcpServer(pool_start::Ipv4Address, pool_end::Ipv4Address, mask::Ipv4Mask, gateway::Ipv4Address)
    DhcpServer(pool_start, pool_end, mask, gateway, Dict{UInt32, Ipv4Address}())
end

"""
    RequestLease(dhcp, node_id) → Ipv4Address
分配 IP 地址
"""
function RequestLease(dhcp::DhcpServer, node_id::UInt32)
    if haskey(dhcp.leases, node_id)
        return dhcp.leases[node_id]
    end
    # 简单分配：基于已分配数偏移
    n = length(dhcp.leases)
    addr_val = dhcp.pool_start.addr + n
    addr = Ipv4Address(addr_val)
    dhcp.leases[node_id] = addr
    return addr
end

"""
    ReleaseLease(dhcp, node_id)
释放 IP 地址
"""
function ReleaseLease(dhcp::DhcpServer, node_id::UInt32)
    delete!(dhcp.leases, node_id)
    nothing
end

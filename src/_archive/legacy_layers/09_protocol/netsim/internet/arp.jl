"""
    ARP — 地址解析协议

对标 ns-3 ArpCache / ArpL3Protocol。
维护 IP→MAC 映射表。
"""
mutable struct ArpEntry
    ip::Ipv4Address
    mac::UInt64
    is_static::Bool
    timeout::Float64  # 超时时间
end

mutable struct ArpCache
    entries::Vector{ArpEntry}
    timeout::Float64  # ARP 缓存超时（秒）
end

ArpCache(;timeout=300.0) = ArpCache(ArpEntry[], timeout)

"""
    ArpLookup(cache, ip) → mac | nothing
"""
function ArpLookup(cache::ArpCache, ip::Ipv4Address)
    for entry in cache.entries
        if entry.ip == ip
            return entry.mac
        end
    end
    return nothing
end

"""
    ArpAdd(cache, ip, mac[; is_static])
"""
function ArpAdd(cache::ArpCache, ip::Ipv4Address, mac::UInt64; is_static=false)
    # 如果已存在，更新
    for entry in cache.entries
        if entry.ip == ip
            entry.mac = mac
            entry.is_static = is_static
            return
        end
    end
    push!(cache.entries, ArpEntry(ip, mac, is_static, Now() + cache.timeout))
    nothing
end

"""
    ArpRemove(cache, ip)
"""
function ArpRemove(cache::ArpCache, ip::Ipv4Address)
    filter!(e -> e.ip != ip, cache.entries)
    nothing
end

"""
    ArpFlush(cache)
"""
function ArpFlush(cache::ArpCache)
    empty!(cache.entries)
    nothing
end

"""
    ArpPrune(cache)
清理超时条目
"""
function ArpPrune(cache::ArpCache)
    now = Now()
    filter!(e -> e.is_static || e.timeout > now, cache.entries)
    nothing
end

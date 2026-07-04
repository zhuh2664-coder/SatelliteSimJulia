"""
    资源层 / 星载缓存模块

    仿真卫星上的内容缓存能力，包括LRU/LFU替换策略和缓存命中率评估。
    流量层（traffic.jl）提供OD对和链路负载，本模块在此基础上计算
    缓存对端到端延迟和骨干网负载的影响。
"""

export SatelliteCache, ContentRequest, lru_update!, lfu_update!, simulate_caching

const DEFAULT_STORAGE_GB = 500.0      # 默认星载存储容量 (GB)
const DEFAULT_CONTENT_SIZE_MB = 50.0   # 默认内容大小 (MB)
const GROUND_DELAY_MS = 50.0           # 地面源获取延迟 (ms)

"""
    SatelliteCache

单颗卫星的缓存状态。

# 字段
- `satellite_id::Int`: 卫星编号
- `capacity_gb::Float64`: 存储容量 (GB)
- `used_gb::Float64`: 已用存储 (GB)
- `content_map::Dict{Int, Float64}`: 缓存的内容ID → 上次访问时间戳
- `hit_count::Int`: 命中次数
- `miss_count::Int`: 未命中次数
"""
mutable struct SatelliteCache
    satellite_id::Int
    capacity_gb::Float64
    used_gb::Float64
    content_map::Dict{Int, Float64}
    access_count::Dict{Int, Int}  # LFU: 内容ID → 访问次数
    hit_count::Int
    miss_count::Int

    function SatelliteCache(sid::Int; cap_gb::Float64 = DEFAULT_STORAGE_GB)
        return new(sid, cap_gb, 0.0, Dict{Int,Float64}(), Dict{Int,Int}(), 0, 0)
    end
end

"""
    ContentRequest

用户内容请求。

# 字段
- `content_id::Int`: 请求的内容ID
- `user_ground_id::Int`: 用户所在的地面站ID
- `size_mb::Float64`: 内容大小 (MB)
- `time_step::Int`: 请求时间
"""
struct ContentRequest
    content_id::Int
    user_ground_id::Int
    size_mb::Float64
    time_step::Int
end

"""
    lru_update!(cache::SatelliteCache, content_id::Int, now::Float64)

LRU 策略：将最近访问的内容移到前面。
如果缓存满，淘汰最久未访问的内容。
"""
function lru_update!(cache::SatelliteCache, content_id::Int, now::Float64)::Bool
    if haskey(cache.content_map, content_id)
        # 内容已在缓存中，更新时间戳
        cache.content_map[content_id] = now
        cache.hit_count += 1
        return true  # 命中
    end

    # 未命中，尝试加入缓存
    content_size_gb = DEFAULT_CONTENT_SIZE_MB / 1000.0
    if cache.used_gb + content_size_gb > cache.capacity_gb
        # 需要淘汰
        if isempty(cache.content_map)
            return false  # 缓存空间不足且无可淘汰内容
        end
        # 找最久未访问的内容
        lru_id = argmin(cache.content_map)
        evicted_size = DEFAULT_CONTENT_SIZE_MB / 1000.0
        delete!(cache.content_map, lru_id)
        delete!(cache.access_count, lru_id)
        cache.used_gb -= evicted_size
    end

    cache.content_map[content_id] = now
    cache.access_count[content_id] = 1
    cache.used_gb += content_size_gb
    cache.miss_count += 1
    return false
end

"""
    lfu_update!(cache::SatelliteCache, content_id::Int, now::Float64) -> Bool

LFU 策略：淘汰访问次数最少的内容。
"""
function lfu_update!(cache::SatelliteCache, content_id::Int, now::Float64)::Bool
    if haskey(cache.content_map, content_id)
        cache.content_map[content_id] = now
        cache.access_count[content_id] += 1
        cache.hit_count += 1
        return true
    end

    content_size_gb = DEFAULT_CONTENT_SIZE_MB / 1000.0
    if cache.used_gb + content_size_gb > cache.capacity_gb
        if isempty(cache.content_map)
            return false
        end
        # 找访问次数最少的
        lfu_id = argmin(cache.access_count)
        evicted_size = DEFAULT_CONTENT_SIZE_MB / 1000.0
        delete!(cache.content_map, lfu_id)
        delete!(cache.access_count, lfu_id)
        cache.used_gb -= evicted_size
    end

    cache.content_map[content_id] = now
    cache.access_count[content_id] = 1
    cache.used_gb += content_size_gb
    cache.miss_count += 1
    return false
end

"""
    simulate_caching(sat_caches, requests, ground_access, ec, strategy::String="lru")
                  -> (avg_hit_rate, avg_delay_ms, backhaul_saved_gb)

运行缓存仿真。

# 参数
- `sat_caches::Vector{SatelliteCache}`: 所有卫星的缓存状态
- `requests::Vector{ContentRequest}`: 内容请求列表
- `ground_access::Matrix{Int}`: [n_ground, n_time] 地面站→卫星接入表
- `ec::Array{Float64,3}`: [n_sat, n_time, 3] 卫星ECEF位置
- `strategy::String`: "lru" 或 "lfu"

# 返回
- `avg_hit_rate::Float64`: 平均缓存命中率 (0~1)
- `avg_delay_ms::Float64`: 平均内容获取延迟 (ms)
- `backhaul_saved_gb::Float64`: 因缓存命中减少的回传流量 (GB)
"""
function simulate_caching(sat_caches::Vector{SatelliteCache},
                          requests::Vector{ContentRequest},
                          ground_access::Matrix{Int},
                          ec::Array{Float64,3};
                          strategy::String = "lru")::Tuple{Float64,Float64,Float64}

    n_sats = length(sat_caches)
    total_hits = 0
    total_delay = 0.0
    backhaul_saved = 0.0
    served = 0

    for req in requests
        t = req.time_step
        gid = req.user_ground_id
        sid = ground_access[gid, t]
        sid <= 0 && continue  # 无卫星接入

        sat = sat_caches[sid]
        now = Float64(t)

        hit = if strategy == "lfu"
            lfu_update!(sat, req.content_id, now)
        else
            lru_update!(sat, req.content_id, now)
        end

        if hit
            total_hits += 1
            total_delay += 1.0  # 星上缓存的延迟 ~1ms
        else
            total_delay += GROUND_DELAY_MS  # 从地面获取
            backhaul_saved += req.size_mb / 1000.0  # 本应回传的数据
        end
        served += 1
    end

    avg_hit = served > 0 ? total_hits / served : 0.0
    avg_del = served > 0 ? total_delay / served : 0.0

    return avg_hit, avg_del, backhaul_saved
end

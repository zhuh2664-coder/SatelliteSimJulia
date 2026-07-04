"""
    资源层 / 内容分发网络仿真模块

    仿真LEO卫星CDN：内容缓存 + 路由分发 + 用户请求处理。
    使用 Distributions.jl 的 Zipf 分布建模内容流行度。
"""

using Distributions

export CDNSatellite, ContentPopularityModel, UserRequest,
       generate_content_catalog!, simulate_user_requests!,
       run_cdn_simulation

const LIGHT_SPEED_MS = 299792.458 / 1000  # 光速 (km/ms)

"""
    ContentPopularityModel

内容流行度模型。
"""
struct ContentPopularityModel
    total_content::Int          # 总内容数
    zipf_exponent::Float64      # Zipf分布参数 (典型值 0.8~1.2)
end

"""
    UserRequest

用户内容请求。
"""
struct UserRequest
    request_id::Int
    content_id::Int
    ground_station_id::Int
    time_step::Int
end

"""
    run_cdn_simulation(sat_caches, requests, ground_access, pop_model)
                   -> (hit_rate, avg_delay_ms, backhaul_pct)

运行CDN仿真。

# 参数
- `sat_caches::Vector{SatelliteCache}`: 卫星缓存状态
- `requests::Vector{UserRequest}`: 用户请求
- `ground_access::Matrix{Int}`: [n_ground, n_time] 接入表
- `pop_model::ContentPopularityModel`: 内容流行度模型

# 返回
- `hit_rate::Float64`: 缓存命中率
- `avg_delay_ms::Float64`: 平均分发延迟 (ms)
- `backhaul_pct::Float64`: 需回程请求占比 (%)
"""
function run_cdn_simulation(sat_caches::Vector{SatelliteCache},
                            requests::Vector{UserRequest},
                            ground_access::Matrix{Float64},
                            pop_model::ContentPopularityModel)::Tuple{Float64,Float64,Float64}

    total_requests = length(requests)
    hits = 0; misses = 0; total_delay = 0.0; backhaul = 0

    for req in requests
        t = req.time_step
        gid = req.ground_station_id
        sid = ground_access[gid, t]
        sid <= 0 && continue

        sat = sat_caches[sid]
        now = Float64(t)
        hit = lru_update!(sat, req.content_id, now)

        if hit
            hits += 1
            total_delay += 2.0  # 卫星到用户 ~2ms
        else
            misses += 1
            total_delay += 50.0  # 地面源 ~50ms
            backhaul += 1
        end
    end

    served = hits + misses
    hit_rate = served > 0 ? hits / served : 0.0
    avg_delay = served > 0 ? total_delay / served : 0.0
    backhaul_pct = served > 0 ? backhaul / served * 100 : 0.0

    return hit_rate, avg_delay, backhaul_pct
end

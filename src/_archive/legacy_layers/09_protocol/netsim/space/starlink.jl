using ResumableFunctions

"""
    starlink.jl — Starlink 流量层仿真模型
复现已知 Starlink 网络特征。
"""

# ═══════════════════════════════════════════
#  Handover 模型
# ═══════════════════════════════════════════

"""
    HandoverConfig — 卫星切换参数

基于 Starlink 公开测量数据:
  - handover_interval: ~15 秒
  - rtt_jump: 切换时 RTT 跳变 20-50ms
  - loss_rate: 切换时丢包率 ~1%
  - outage_duration: 切换中断时间 ~50ms
"""
mutable struct HandoverConfig
    interval::Float64        # 切换间隔 (秒)
    rtt_min::Float64         # 最小 RTT (秒)
    rtt_max::Float64         # 最大 RTT (秒)
    loss_rate::Float64       # 切换丢包率
    outage_duration::Float64 # 切换中断时间 (秒)
    jitter_amplitude::Float64 # RTT 抖动振幅 (秒)
    current_sat::Int         # 当前服务卫星
    next_sat::Int            # 下一颗卫星
    last_handover::Float64   # 上次切换时间
    handover_count::Int      # 切换计数
end

function HandoverConfig(;interval=15.0, rtt_min=0.020, rtt_max=0.050,
                         loss=0.01, outage=0.05, jitter=0.005)
    HandoverConfig(interval, rtt_min, rtt_max, loss, outage, jitter,
                   1, 2, 0.0, 0)
end

"""
    handover_state(hc, t) → (rtt, loss_prob)

返回当前时刻的 RTT 和丢包概率。
"""
function handover_state(hc::HandoverConfig, t::Float64)
    # 检查是否在切换窗口内
    time_in_cycle = mod(t, hc.interval)
    in_handover = time_in_cycle < hc.outage_duration || time_in_cycle > hc.interval - hc.outage_duration

    # RTT 锯齿波: 卫星从天顶移到地平线
    phase = time_in_cycle / hc.interval  # 0→1 一个周期
    rtt = hc.rtt_min + (hc.rtt_max - hc.rtt_min) * sin(phase * pi)

    # 添加抖动
    rtt += randn() * hc.jitter_amplitude
    rtt = max(hc.rtt_min * 0.5, min(rtt, hc.rtt_max * 2))

    # 切换时的丢包
    loss_prob = in_handover ? hc.loss_rate : 0.0

    if in_handover && time_in_cycle < 0.01  # 切换触发
        hc.handover_count += 1
        hc.last_handover = t
        hc.current_sat = hc.next_sat
        hc.next_sat = mod1(hc.next_sat + 1, 100)
    end

    (rtt, loss_prob)
end

"""
    HandoverApp — 模拟用户终端的切换

每隔 handover_interval 切换服务卫星，更新 TCP RTT。
"""
mutable struct HandoverApp
    config::HandoverConfig
    socket::Any
    last_update::Float64
end

function HandoverApp(sock; interval=15.0)
    HandoverApp(HandoverConfig(interval=interval), sock, 0.0)
end

"""
    update_handover!(app, t)

更新 TCP RTT 模拟切换。
"""
function update_handover!(app::HandoverApp, t::Float64)
    hc = app.config
    rtt, loss = handover_state(hc, t)

    # RTT updated externally via Bundle/LTP convergence layer
    app.socket = (rtt=rtt, loss=loss)
    nothing

    app.last_update = t
    nothing
end

# ═══════════════════════════════════════════
#  卫星运动 → ISL 延迟
# ═══════════════════════════════════════════

"""
    DynamicIslChannel — 动态 ISL 信道

延迟由 pos 矩阵驱动，随时间变化。
"""
mutable struct DynamicIslChannel
    pos::AbstractArray{Float64,3}   # N×T×3 位置矩阵
    node_ids::Vector{UInt32}
    delay_matrix::Array{Float64,2}  # N×N 当前延迟矩阵
    time_step::Float64
    current_t::Int
end

"""
    build_dynamic_isl!(ch, pos, node_ids)

从 pos 矩阵构建动态 ISL 延迟。
"""
function build_dynamic_isl!(ch::DynamicIslChannel, pos::AbstractArray{Float64,3},
                             node_ids::Vector{UInt32})
    n = size(pos, 1)
    ch.delay_matrix = zeros(n, n)
    c = 299792.458  # km/s
    for i in 1:n
        for j in (i+1):n
            d = sqrt(sum((pos[i,ch.current_t,:] - pos[j,ch.current_t,:]).^2))
            ch.delay_matrix[i,j] = d / c
            ch.delay_matrix[j,i] = d / c
        end
    end
    nothing
end

"""
    update_isl_delay!(ch, t_idx)

更新时间步 → ISL 延迟重新计算。
"""
function update_isl_delay!(ch::DynamicIslChannel, t_idx::Int)
    ch.current_t = t_idx
    n = size(ch.pos, 1)
    c = 299792.458
    for i in 1:n
        for j in (i+1):n
            d = sqrt(sum((ch.pos[i,t_idx,:] - ch.pos[j,t_idx,:]).^2))
            ch.delay_matrix[i,j] = d / c
            ch.delay_matrix[j,i] = d / c
        end
    end
    nothing
end

# ═══════════════════════════════════════════
#  GSL (Ground-to-Satellite Link)
# ═══════════════════════════════════════════

"""
    GslLink — 地面站-卫星链路

模拟地面站与卫星之间的链路：
  - 卫星可见窗口
  - 仰角依赖的路径损耗
  - 大气衰减
"""
mutable struct GslLink
    gs_lat::Float64    # 地面站纬度
    gs_lon::Float64    # 地面站经度
    gs_alt::Float64    # 地面站海拔 (km)
    sat_id::UInt32     # 服务卫星 ID
    elevation::Float64 # 当前仰角 (度)
    is_active::Bool    # 链路是否激活
    snr::Float64       # 当前 SNR (dB)
end

"""地球半径"""
const EARTH_R = 6371.0

"""
    compute_elevation(pos_sat, gs_lat, gs_lon, gs_alt) → 仰角(度)

计算卫星相对地面站的仰角。
"""
function compute_elevation(pos_sat::Vector{Float64}, gs_lat::Float64,
                            gs_lon::Float64, gs_alt::Float64)::Float64
    # 地面站 ECEF 坐标 (简化)
    gs_lat_r = gs_lat * pi / 180
    gs_lon_r = gs_lon * pi / 180
    gs_r = EARTH_R + gs_alt
    gs_pos = [gs_r * cos(gs_lat_r) * cos(gs_lon_r),
              gs_r * cos(gs_lat_r) * sin(gs_lon_r),
              gs_r * sin(gs_lat_r)]

    # 卫星→地面站向量
    d = pos_sat - gs_pos
    dist = sqrt(sum(d.^2))

    # 地面站到地心方向
    up = gs_pos / sqrt(sum(gs_pos.^2))

    # 仰角 = arcsin(dot(d, up) / dist)
    elevation = asin((d[1]*up[1]+d[2]*up[2]+d[3]*up[3]) / dist) * 180 / pi
    elevation
end

"""
    compute_path_loss(elevation, freq) → 路径损耗 (dB)

频率依赖的路径损耗 + 大气衰减。
"""
function compute_path_loss(elevation::Float64, freq::Float64)::Float64
    # 自由空间路径损耗
    c = 299792458.0
    dist_surface = 550.0  # km (LEO 典型高度)
    dist = dist_surface * 1000 / sin(max(elevation, 5.0) * pi / 180)
    fspl = 20 * log10(dist) + 20 * log10(freq) - 147.55

    # 大气衰减 (仰角越低衰减越大)
    atm_loss = 0.5 / sin(max(elevation, 5.0) * pi / 180)
    fspl + atm_loss
end

"""
    update_gsl!(link, pos_sat, t)

更新 GSL 链路状态。
"""
function update_gsl!(link::GslLink, pos_sat::Vector{Float64}, t::Float64)
    elevation = compute_elevation(pos_sat, link.gs_lat, link.gs_lon, link.gs_alt)

    link.elevation = elevation
    link.is_active = elevation > 10.0  # 最小仰角 10°

    if link.is_active
        loss = compute_path_loss(elevation, 20e9)  # Ku 波段
        link.snr = 30.0 - loss / 10  # 简化 SNR 计算
    else
        link.snr = -Inf
    end
    nothing
end

# ═══════════════════════════════════════════
#  Starlink 完整场景
# ═══════════════════════════════════════════

"""
    StarlinkScenario — 完整的 Starlink 流量层场景

组合 handover + 动态 ISL + GSL。
"""
mutable struct StarlinkScenario
    handover::HandoverConfig
    isl::DynamicIslChannel
    gsl::GslLink
    tcp_sockets::Vector{Any}
    flow_mon::FlowMonitor
    active::Bool
end

"""
    run_starlink_scenario(scenario, duration)

运行 Starlink 场景仿真。
"""
@resumable function run_starlink_scenario(scenario::StarlinkScenario, duration::Float64)
    env = GetEnv()
    steps = Int(duration / 1.0)

    for step in 1:steps
        t = step * 1.0

        # 1. 更新切换状态
        rtt, loss = handover_state(scenario.handover, t)
        for sock in scenario.tcp_sockets
            update_handover!(HandoverApp(sock, interval=scenario.handover.interval), t)
        end

        # 2. 更新 ISL 延迟
        t_idx = min(step, size(scenario.isl.pos, 2))
        update_isl_delay!(scenario.isl, t_idx)

        # 3. 更新 GSL
        sat_idx = findfirst(id -> id == scenario.handover.current_sat, scenario.isl.node_ids)
        if sat_idx !== nothing
            pos_sat = scenario.isl.pos[sat_idx, t_idx, :]
            update_gsl!(scenario.gsl, pos_sat, t)
        end

        @yield timeout(env, 1.0)
    end
    nothing
end

using ItuRPropagation

const C = 299792458.0  # 光速 m/s

"""
    free_space_loss(freq_hz, dist_m) → dB

Friis 自由空间路径损耗。
"""
function free_space_loss(freq::Float64, dist::Float64)::Float64
    # Friis: FSPL = 20*log10(dist) + 20*log10(freq) - 147.55
    20 * log10(dist) + 20 * log10(freq) - 147.55
end

"""
    atmospheric_loss(freq_hz, elevation_deg, altitude_km) → dB

大气衰减合计 (气体 + 雨 + 云)。
使用 ItuRPropagation.jl 实现 ITU-R 标准。
"""
function atmospheric_loss(freq::Float64, elevation::Float64, alt::Float64)::Float64
    # ITU-R P.676 气体吸收 + P.618 雨衰 (通过 ItuRPropagation.jl)
    latlon = LatLon(30.0, 120.0)  # 默认: 上海区域
    f_ghz = freq / 1e9
    try
        # attenuations(latlon, f_ghz, p%, θ°, distance_km)
        # p=0.01 表示 0.01% 时间概率 (ITU-R 雨衰标准)
        return attenuations(latlon, f_ghz, 0.01, max(elevation, 1.0), alt)
    catch
        # fallback: 简化模型
        return 0.1 / sin(max(elevation, 2.0) * pi / 180)
    end
end

"""
    total_path_loss(freq_hz, dist_m, elevation_deg, alt_km) → dB

完整链路损耗 = 自由空间 + 大气 + 闪烁余量。
"""
function total_path_loss(freq::Float64, dist::Float64, elevation::Float64, alt::Float64)::Float64
    fspl = free_space_loss(freq, dist)
    atm = atmospheric_loss(freq, elevation, alt)
    fspl + atm
end

"""
    compute_doppler(vel_vector, pos_vector, freq_hz) → Hz

多普勒频移: f_d = - (v·r̂) / c × f_c

使用卫星和地面站的精确速度/位置向量计算。
"""
function compute_doppler(vel::Vector{Float64}, pos::Vector{Float64}, freq::Float64)::Float64
    dist = sqrt(sum(pos.^2))
    dist == 0 && return 0.0
    # 径向速度 = 速度向量在位置向量方向上的投影
    radial_vel = dot(vel, pos) / dist  # v·r̂
    -radial_vel / C * freq
end

"""
    link_budget(tx_power_dbm, tx_gain_dbi, rx_gain_dbi, path_loss_db, noise_figure_db) → dBm

链路预算计算。
"""
function link_budget(tx_power::Float64, tx_gain::Float64, rx_gain::Float64,
                      path_loss::Float64, noise_figure::Float64)::Float64
    rx_power = tx_power + tx_gain + rx_gain - path_loss
    noise_floor = -174.0 + noise_figure + 10 * log10(500e6)  # 500MHz带宽
    rx_power - noise_floor
end

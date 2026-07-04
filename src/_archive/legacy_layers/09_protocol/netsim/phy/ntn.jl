
using Distributions

# NTN 场景类型
const NTN_LEO = 0
const NTN_MEO = 1
const NTN_GEO = 2

# 频段
const BAND_S = 2e9
const BAND_C = 4e9
const BAND_KU = 12e9
const BAND_KA = 20e9

# NTN 场景参数 (TR 38.811 Table 6.1-1)
struct NtnScenarioParams
    altitude::Float64       # km
    min_elevation::Float64  # 度
    max_distance::Float64   # km
    delay_min::Float64      # ms (单向传播延迟)
    delay_max::Float64      # ms
    doppler_max::Float64    # kHz
    k_factor::Float64       # 莱斯 K 因子 (dB)
end

const NTN_PARAMS = Dict(
    NTN_LEO => NtnScenarioParams(600, 10, 2000, 3, 12, 40, 10.0),
    NTN_MEO => NtnScenarioParams(2000, 10, 10000, 10, 50, 20, 12.0),
    NTN_GEO => NtnScenarioParams(35786, 5, 40000, 120, 140, 0.2, 15.0),
)

"""
    NtnChannelConfig — NTN 信道配置

参数覆盖 TR 38.811 Table 6.1-1。
"""
mutable struct NtnChannelConfig
    scenario::Int          # NTN_LEO / NTN_MEO / NTN_GEO
    frequency::Float64     # Hz
    bandwidth::Float64     # Hz
    elevation::Float64     # 当前仰角 (度)
    distance::Float64      # 当前距离 (km)
    velocity_radial::Float64  # 径向速度 (km/s)
end

"""
    NtnChannelState — NTN 信道状态
"""
mutable struct NtnChannelState
    path_loss_db::Float64     # 路径损耗 (dB)
    doppler_shift_hz::Float64 # 多普勒频移 (Hz)
    k_factor_db::Float64      # 莱斯 K 因子 (dB)
    los_probability::Float64  # LOS 概率
    delay_spread_s::Float64   # 时延扩展 (s)
    sinr_db::Float64          # 信干噪比 (dB)
    is_los::Bool              # 是否 LOS
end

"""
    ntn_los_probability(elevation, scenario) → 概率

3GPP TR 38.811 Table 6.1-2: LOS 概率 vs 仰角。
"""
function ntn_los_probability(elevation::Float64, scenario::Int)::Float64
    elev_rad = elevation * pi / 180
    if scenario == NTN_LEO
        return 1 - 0.5 * exp(-elevation / 10.0)
    elseif scenario == NTN_MEO
        return 1 - 0.3 * exp(-elevation / 15.0)
    else  # GEO
        return 1 - 0.1 * exp(-elevation / 20.0)
    end
end

"""
    ntn_k_factor(elevation, scenario) → dB

3GPP TR 38.811 Table 6.1-3: 莱斯 K 因子。
"""
function ntn_k_factor(elevation::Float64, scenario::Int)::Float64
    params = NTN_PARAMS[scenario]
    if scenario == NTN_LEO
        return params.k_factor + 0.5 * elevation
    else
        return params.k_factor + 0.2 * elevation
    end
end

"""
    ntn_channel(config) → NtnChannelState

计算 NTN 信道的完整状态。
"""
function ntn_channel(config::NtnChannelConfig)::NtnChannelState
    params = NTN_PARAMS[config.scenario]
    c = 299792458.0

    # 路径损耗 (自由空间 + 大气)
    dist_m = config.distance * 1000
    fspl = 20 * log10(dist_m) + 20 * log10(config.frequency) - 147.55

    # 大气衰减 (仰角越低越严重)
    atm_loss = 0.5 / sin(max(config.elevation, 1.0) * pi / 180)

    path_loss = fspl + atm_loss

    # 多普勒频移
    doppler = -config.velocity_radial * 1000 / c * config.frequency

    # LOS 概率
    los_prob = ntn_los_probability(config.elevation, config.scenario)
    is_los = rand() < los_prob

    # 莱斯 K 因子
    k = ntn_k_factor(config.elevation, config.scenario)

    # 时延扩展 (TR 38.811 Table 6.1-4)
    delay_spread = 100e-9  # 100ns 典型值 (LEO)

    # 简化 SINR
    noise_floor = -174.0 + 5.0 + 10 * log10(config.bandwidth)
    sinr = 30.0 - path_loss + 35.0 - noise_floor  # tx_power=30dBm, tx_gain=35dBi

    NtnChannelState(path_loss, doppler, k, los_prob, delay_spread, sinr, is_los)
end

"""
    ntn_apply_fading(channel_state, signal) → 衰落后的信号

应用莱斯衰落 + 多普勒到信号。
"""
function ntn_apply_fading(state::NtnChannelState, signal::Vector{ComplexF64})::Vector{ComplexF64}
    k_linear = 10^(state.k_factor_db / 10)

    # 莱斯衰落: LOS 分量 + 散射分量
    los = sqrt(k_linear / (k_linear + 1))
    nlos = sqrt(1 / (k_linear + 1)) * (randn() + 1im * randn()) / sqrt(2)

    # 多普勒相移
    doppler_phase = 2 * pi * state.doppler_shift_hz * (0:length(signal)-1) / 500e6

    fading = los * exp.(1im * doppler_phase) .+ nlos
    signal .* fading
end

"""
    NtnGwConfig — NTN 地面站/馈电链路配置
"""
mutable struct NtnGwConfig
    gw_id::UInt32
    lat::Float64
    lon::Float64
    alt::Float64
    beamwidth::Float64  # 波束宽度 (度)
    max_power::Float64  # 最大发射功率 (dBm)
end

"""
    ntn_feeder_link(gw, sat_pos, freq) → (path_loss, doppler)

NTN 馈电链路 (地面站 → 卫星上行的完整链路预算)。
"""
function ntn_feeder_link(gw::NtnGwConfig, sat_pos::Vector{Float64}, freq::Float64)
    # 地面站到卫星的距离和仰角
    gs_pos = [6371e3 * cos(gw.lat*pi/180) * cos(gw.lon*pi/180),
              6371e3 * cos(gw.lat*pi/180) * sin(gw.lon*pi/180),
              6371e3 * sin(gw.lat*pi/180)]
    d = sat_pos - gs_pos
    dist_km = sqrt(sum(d.^2)) / 1000

    # 仰角
    up = gs_pos / sqrt(sum(gs_pos.^2))
    elevation = asin((d[1]*up[1] + d[2]*up[2] + d[3]*up[3]) / (dist_km * 1000)) * 180 / pi

    # 链路损耗
    fspl = 20 * log10(dist_km * 1000) + 20 * log10(freq) - 147.55
    atm = 0.5 / sin(max(elevation, 1.0) * pi / 180)

    (fspl + atm, elevation)
end

# (loss_model.jl 已在 NetSim 模块中先行 include)

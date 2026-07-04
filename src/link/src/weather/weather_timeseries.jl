# ===== 天气感知容量模型 + 马尔可夫雨衰合成 =====
#
# B4: 把 ITU-R 统计雨衰桥接到逐时间步的衰减序列（马尔可夫链）。
# B5: 天气感知容量模型，接入链路评估（下雨时 GSL 自动降速）。
#
# 新增于 2026-07-04（Phase 4 - B4/B5）。

using Random

# 注意：rain_attenuation/link_budget/dvbs2_modcod 都在同模块内，直接引用符号
# 不需要 using SatelliteSimLink（会自引用）

export
    WeatherState,
    WeatherTimeSeries,
    generate_rain_attenuation_series,
    WeatherAwareCapacityModel,
    weather_aware_capacity_mbps

# ════════════════════════════════════════════════════════════
# B4: 马尔可夫雨衰合成
# ════════════════════════════════════════════════════════════

"""
    WeatherState

某时间步的天气状态。

# 字段
- `time_index::Int`: 时隙索引
- `elapsed_s::Int`: 仿真秒数
- `rain_rate_mm_h::Float64`: 当前降雨率
- `rain_attenuation_db::Float64`: 当前雨衰
- `is_raining::Bool`: 是否在下雨
"""
struct WeatherState
    time_index::Int
    elapsed_s::Int
    rain_rate_mm_h::Float64
    rain_attenuation_db::Float64
    is_raining::Bool
end

"""
    WeatherTimeSeries

天气状态时间序列。
"""
struct WeatherTimeSeries
    states::Vector{WeatherState}
end

"""
    generate_rain_attenuation_series(
        n_steps, step_s, rain_params_base;
        rain_probability, mean_rain_rate, rain_rate_std,
        transition_dry_to_wet, transition_wet_to_dry, rng
    ) -> WeatherTimeSeries

生成雨衰时间序列（两态马尔可夫链：晴/雨）。

# 模型
两态马尔可夫链：
- 状态 DRY（晴）：雨衰=0
- 状态 WET（雨）：雨衰由雨率计算（对数正态分布）

转移概率（每步）：
- DRY→WET: transition_dry_to_wet（典型 0.01-0.05）
- WET→DRY: transition_wet_to_dry（典型 0.1-0.3）
- 稳态雨概率 = p_DW / (p_DW + p_WD)

# 参数
- `n_steps::Int`: 时间步数
- `step_s::Int`: 每步秒数
- `rain_params_base::RainParameters`: 雨衰计算基础参数（频率/仰角/纬度）
- `rain_probability::Float64`: 目标稳态雨概率（0-1，如 0.05=5%时间下雨）
- `mean_rain_rate::Float64`: 下雨时平均雨率（mm/h）
- `rng::AbstractRNG`: 随机数生成器

# 返回
WeatherTimeSeries，每个时间步一个 WeatherState。
"""
function generate_rain_attenuation_series(
    n_steps::Int,
    step_s::Int,
    rain_params_base::RainParameters;
    rain_probability::Float64 = 0.05,
    mean_rain_rate::Float64 = 15.0,
    rain_rate_std::Float64 = 10.0,
    rng::AbstractRNG = Random.default_rng(),
)::WeatherTimeSeries
    n_steps > 0 || throw(ArgumentError("n_steps must be positive"))
    0 <= rain_probability <= 1 || throw(ArgumentError("rain_probability must be in [0,1]"))

    # 由目标稳态概率推转移概率
    # 稳态 P(WET) = p_DW / (p_DW + p_WD)
    # 设 p_WD = 0.2（雨平均持续 5 步），解 p_DW
    p_WD = 0.2  # WET→DRY
    p_DW = rain_probability * p_WD / (1 - rain_probability)  # DRY→WET

    states = Vector{WeatherState}()
    is_wet = rand(rng) < rain_probability  # 初始状态按稳态概率采样

    for t in 1:n_steps
        elapsed_s = (t - 1) * step_s
        if is_wet
            # 对数正态雨率
            σ = rain_rate_std > 0 ? rain_rate_std / mean_rain_rate : 0.5
            μ_ln = log(mean_rain_rate) - σ^2 / 2
            u1 = rand(rng); u2 = rand(rng)
            z = sqrt(-2log(u1)) * cos(2π * u2)
            rain_rate = max(0.1, exp(μ_ln + σ * z))
        else
            rain_rate = 0.0
        end

        # 算雨衰（复制基础参数，替换雨率）
        rp = RainParameters(;
            frequency_ghz = rain_params_base.frequency_ghz,
            elevation_deg = rain_params_base.elevation_deg,
            rain_rate_mm_h = rain_rate,
            latitude_deg = rain_params_base.latitude_deg,
            altitude_km = rain_params_base.altitude_km,
            polarization = rain_params_base.polarization,
            tau_deg = rain_params_base.tau_deg,
        )
        A = rain_attenuation_db(rp)

        push!(states, WeatherState(t, elapsed_s, rain_rate, A, is_wet))

        # 状态转移
        if is_wet
            is_wet = rand(rng) >= p_WD  # 1-p_WD 继续 WET
        else
            is_wet = rand(rng) < p_DW
        end
    end

    return WeatherTimeSeries(states)
end

# ════════════════════════════════════════════════════════════
# B5: 天气感知容量模型
# ════════════════════════════════════════════════════════════

"""
    WeatherAwareCapacityModel

天气感知容量模型：结合链路预算（含雨衰）+ DVB-S2 ACM。

# 字段
- `tx_power_dbw::Float64`: 发射功率
- `tx_antenna_gain_dbi::Float64`: 发射天线增益
- `rx_antenna_gain_dbi::Float64`: 接收天线增益
- `system_noise_temp_k::Float64`: 系统噪声温度
- `bandwidth_hz::Float64`: 噪声带宽
- `symbol_rate_mbaud::Float64`: DVB-S2 符号率（Mbaud）
- `frequency_ghz::Float64`: 载波频率
- `latitude_deg::Float64`: 地面站纬度
- `altitude_km::Float64`: 地面站海拔
- `tau_deg::Float64`: 极化倾角
- `atmospheric_loss_db::Float64`: 晴空大气损耗
"""
struct WeatherAwareCapacityModel
    tx_power_dbw::Float64
    tx_antenna_gain_dbi::Float64
    rx_antenna_gain_dbi::Float64
    system_noise_temp_k::Float64
    bandwidth_hz::Float64
    symbol_rate_mbaud::Float64
    frequency_ghz::Float64
    latitude_deg::Float64
    altitude_km::Float64
    tau_deg::Float64
    atmospheric_loss_db::Float64
end

WeatherAwareCapacityModel(;
    tx_power_dbw::Float64 = 15.0,
    tx_antenna_gain_dbi::Float64 = 35.0,
    rx_antenna_gain_dbi::Float64 = 41.0,
    system_noise_temp_k::Float64 = 140.0,
    bandwidth_hz::Float64 = 250e6,
    symbol_rate_mbaud::Float64 = 250.0,  # 250 Mbaud
    frequency_ghz::Float64 = 30.0,
    latitude_deg::Float64 = 40.0,
    altitude_km::Float64 = 0.0,
    tau_deg::Float64 = 45.0,
    atmospheric_loss_db::Float64 = 0.5,
) = WeatherAwareCapacityModel(
    tx_power_dbw, tx_antenna_gain_dbi, rx_antenna_gain_dbi,
    system_noise_temp_k, bandwidth_hz, symbol_rate_mbaud,
    frequency_ghz, latitude_deg, altitude_km, tau_deg, atmospheric_loss_db,
)

"""
    weather_aware_capacity_mbps(
        model::WeatherAwareCapacityModel,
        elevation_deg::Float64,
        distance_km::Float64,
        rain_rate_mm_h::Float64,
    ) -> Float64

天气感知容量：按当前仰角/距离/雨率算链路预算 → SNR → ACM 容量。

# 算法
1. 构造 RainParameters（如果雨率>0）
2. 算链路预算 C/N₀ → SNR
3. 按 SNR 选 DVB-S2 MODCOD
4. 容量 = 频谱效率 × 符号率

# 返回
有效容量（Mbps），0=链路中断
"""
function weather_aware_capacity_mbps(
    model::WeatherAwareCapacityModel,
    elevation_deg::Float64,
    distance_km::Float64,
    rain_rate_mm_h::Float64,
)::Float64
    # 雨衰参数
    rain_params = rain_rate_mm_h > 0 ? RainParameters(;
        frequency_ghz = model.frequency_ghz,
        elevation_deg = elevation_deg,
        rain_rate_mm_h = rain_rate_mm_h,
        latitude_deg = model.latitude_deg,
        altitude_km = model.altitude_km,
        tau_deg = model.tau_deg,
    ) : nothing

    # 链路预算
    lb = link_budget(;
        tx_power_dbw = model.tx_power_dbw,
        tx_antenna_gain_dbi = model.tx_antenna_gain_dbi,
        frequency_ghz = model.frequency_ghz,
        distance_km = distance_km,
        rx_antenna_gain_dbi = model.rx_antenna_gain_dbi,
        system_noise_temp_k = model.system_noise_temp_k,
        bandwidth_hz = model.bandwidth_hz,
        rain_params = rain_params,
        atmospheric_loss_db = model.atmospheric_loss_db,
    )

    # ACM 容量
    return acm_capacity_mbps(lb.snr_db, model.symbol_rate_mbaud)
end

"""
    weather_aware_capacity_series(
        model::WeatherAwareCapacityModel,
        elevation_deg::Float64,
        distance_km::Float64,
        weather::WeatherTimeSeries,
    ) -> Vector{Float64}

按天气时间序列算每个时间步的天气感知容量。
"""
function weather_aware_capacity_series(
    model::WeatherAwareCapacityModel,
    elevation_deg::Float64,
    distance_km::Float64,
    weather::WeatherTimeSeries,
)::Vector{Float64}
    return [
        weather_aware_capacity_mbps(model, elevation_deg, distance_km, ws.rain_rate_mm_h)
        for ws in weather.states
    ]
end

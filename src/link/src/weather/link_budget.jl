# ===== 链路预算耦合（雨衰 → C/N₀ → 有效 SNR）=====
#
# 把 ITU-R P.618 雨衰折进链路预算，算有效载噪比 C/N₀。
# 这是天气模型到链路质量的关键桥梁。
#
# 新增于 2026-07-04（Phase 3 - B2）。

using SatelliteSimLink: rain_attenuation_db, RainParameters

export
    LinkBudget,
    link_budget,
    cnr_db,
    snr_db,
    link_margin_db

# 物理常量
const _BOLTZMANN_DBW_K_HZ = -228.6  # 玻尔兹曼常数 dBW/(K·Hz)

"""
    LinkBudget

链路预算结果。

# 字段
- `eirp_dbw::Float64`: 有效全向辐射功率（dBW）
- `free_space_loss_db::Float64`: 自由空间路径损耗（dB）
- `rain_attenuation_db::Float64`: 雨衰（dB）
- `atmospheric_loss_db::Float64`: 晴空大气/气体损耗（dB，默认 0.5）
- `gt_db_k::Float64`: 接收端品质因数 G/T（dB/K）
- `cnr_db_hz::Float64`: 载噪比 C/N₀（dB·Hz）
- `bandwidth_hz::Float64`: 噪声带宽（Hz）
- `snr_db::Float64`: 信噪比 SNR = C/N₀ - 10log₁₀(B)
- `margin_db::Float64`: 链路余量（相对所需 SNR）
"""
struct LinkBudget
    eirp_dbw::Float64
    free_space_loss_db::Float64
    rain_attenuation_db::Float64
    atmospheric_loss_db::Float64
    gt_db_k::Float64
    cnr_db_hz::Float64
    bandwidth_hz::Float64
    snr_db::Float64
    margin_db::Float64
end

"""
    link_budget(;
        tx_power_dbw, tx_antenna_gain_dbi,
        frequency_ghz, distance_km,
        rx_antenna_gain_dbi, system_noise_temp_k,
        bandwidth_hz,
        rain_params::Union{Nothing,RainParameters},
        atmospheric_loss_db, required_snr_db
    ) -> LinkBudget

完整链路预算。

# 算法
- EIRP = P_tx + G_tx
- 自由空间损耗 FSL = 20·log₁₀(4π·d·f/c)
- C/N₀ = EIRP - FSL - A_rain - A_atm + G/T - k
- SNR = C/N₀ - 10log₁₀(B)
- margin = SNR - required_snr

# 参数
- `tx_power_dbw::Float64`: 发射功率（dBW）
- `tx_antenna_gain_dbi::Float64`: 发射天线增益（dBi）
- `frequency_ghz::Float64`: 载波频率（GHz）
- `distance_km::Float64`: 斜距（km）
- `rx_antenna_gain_dbi::Float64`: 接收天线增益（dBi）
- `system_noise_temp_k::Float64`: 系统噪声温度（K）
- `bandwidth_hz::Float64`: 噪声带宽（Hz）
- `rain_params::Union{Nothing,RainParameters}`: 雨衰参数（nothing=晴空）
- `atmospheric_loss_db::Float64`: 晴空大气损耗（dB，默认 0.5）
- `required_snr_db::Float64`: 所需 SNR（dB，用于算余量）
"""
function link_budget(;
    tx_power_dbw::Float64,
    tx_antenna_gain_dbi::Float64,
    frequency_ghz::Float64,
    distance_km::Float64,
    rx_antenna_gain_dbi::Float64,
    system_noise_temp_k::Float64,
    bandwidth_hz::Float64,
    rain_params::Union{Nothing,RainParameters} = nothing,
    atmospheric_loss_db::Float64 = 0.5,
    required_snr_db::Float64 = 5.0,
)::LinkBudget
    # EIRP
    eirp = tx_power_dbw + tx_antenna_gain_dbi

    # 自由空间损耗
    c_km_s = 299792.458  # 光速 km/s
    wavelength_km = c_km_s / (frequency_ghz * 1e9)  # f 转 Hz 再除
    fsl = 20 * log10(4π * distance_km / wavelength_km)

    # 雨衰
    A_rain = rain_params === nothing ? 0.0 : rain_attenuation_db(rain_params)

    # G/T (dB/K)
    gt = rx_antenna_gain_dbi - 10 * log10(system_noise_temp_k)

    # C/N₀ = EIRP - FSL - A_rain - A_atm + G/T - k
    cnr = eirp - fsl - A_rain - atmospheric_loss_db + gt - _BOLTZMANN_DBW_K_HZ

    # SNR = C/N₀ - 10log₁₀(B)
    snr = cnr - 10 * log10(bandwidth_hz)

    # 链路余量
    margin = snr - required_snr_db

    return LinkBudget(eirp, fsl, A_rain, atmospheric_loss_db, gt, cnr, bandwidth_hz, snr, margin)
end

"""
    cnr_db(lb::LinkBudget) -> Float64

返回 C/N₀（dB·Hz）。
"""
cnr_db(lb::LinkBudget) = lb.cnr_db_hz

"""
    snr_db(lb::LinkBudget) -> Float64

返回 SNR（dB）。
"""
snr_db(lb::LinkBudget) = lb.snr_db

"""
    link_margin_db(lb::LinkBudget) -> Float64

返回链路余量（dB）。正值=链路闭合，负值=链路中断。
"""
link_margin_db(lb::LinkBudget) = lb.margin_db

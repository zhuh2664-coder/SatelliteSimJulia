"""
    WifiPhy — 802.11 PHY（占位）

对标 ns-3 WifiPhy。
待实现：OFDM/OFDMA 调制编码、MCS 选择、802.11ax/be 等。
"""
abstract type WifiStandard end
struct WiFi80211n <: WifiStandard end
struct WiFi80211ac <: WifiStandard end
struct WiFi80211ax <: WifiStandard end
struct WiFi80211be <: WifiStandard end

mutable struct WifiPhy
    standard::WifiStandard
    channel_width::Int       # MHz (20/40/80/160)
    tx_power::Float64        # dBm
    noise_figure::Float64    # dB
    sensitivity::Float64     # dBm
end

WifiPhy(;standard=WiFi80211ax(), channel_width=80,
        tx_power=20.0, noise_figure=7.0, sensitivity=-82.0) =
    WifiPhy(standard, channel_width, tx_power, noise_figure, sensitivity)

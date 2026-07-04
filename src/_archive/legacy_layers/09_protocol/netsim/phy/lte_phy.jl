"""
    LtePhy — LTE PHY（占位）

对标 ns-3 LtePhy。
待实现：OFDMA/SC-FDMA 资源分配、MIMO、HARQ 等。
"""
mutable struct LtePhy
    bandwidth::Int           # MHz (1.4/3/5/10/15/20)
    tx_power::Float64        # dBm
    noise_figure::Float64    # dB
    num_antennas::Int        # MIMO 天线数
end

LtePhy(;bandwidth=10, tx_power=23.0, noise_figure=5.0, num_antennas=2) =
    LtePhy(bandwidth, tx_power, noise_figure, num_antennas)

"""
    spectrum.jl — 频谱信道模型

对标 ns-3 spectrum 模块。
频域信号表示、干扰建模、SINR 计算、OFDM 参数。
"""
struct SpectrumValue
    power_spectral_density::Vector{Float64}  # dBm/Hz
    frequencies::Vector{Float64}              # Hz (中心频率列表)
end

num_subbands(sv::SpectrumValue) = length(sv.power_spectral_density)
total_power(sv::SpectrumValue) = sum(sv.power_spectral_density)

""" 频谱信道：管理频率资源、干扰聚合 """
mutable struct SpectrumChannel
    id::Int
    center_frequency::Float64
    bandwidth::Float64
    num_subbands::Int
    noise_figure::Float64      # dB
    noise_temperature::Float64  # K

    # 活跃信号
    active_signals::Vector{Tuple{UInt32, SpectrumValue, Vector{UInt32}}}
    # (node_id, signal, affected_nodes)
end

function SpectrumChannel(;freq=20e9, bw=500e6, subbands=100, nf=5.0, temp=290.0)
    SpectrumChannel(0, freq, bw, subbands, nf, temp, [])
end

""" 添加信号到信道 """
function add_signal(ch::SpectrumChannel, src::UInt32,
                    power::Float64, affected::Vector{UInt32})
    # 构造频谱值 (均匀功率谱密度)
    psd = fill(power / ch.num_subbands / ch.bandwidth, ch.num_subbands)
    sv = SpectrumValue(psd, collect(range(ch.center_frequency - ch.bandwidth/2,
                                          ch.center_frequency + ch.bandwidth/2,
                                          length=ch.num_subbands)))
    push!(ch.active_signals, (src, sv, affected))
end

""" 清除信号 """
function clear_signals(ch::SpectrumChannel)
    empty!(ch.active_signals)
end

""" 计算噪声功率 """
function noise_power(ch::SpectrumChannel, subband_width::Float64)
    k = 1.380649e-23  # Boltzmann 常数
    nf_linear = 10^(ch.noise_figure / 10)
    return k * ch.noise_temperature * subband_width * nf_linear
end

""" 计算 SINR (dB) """
function sinr(ch::SpectrumChannel, rx_power::Float64,
              node_id::UInt32, subband_idx::Int)
    # 信号功率
    signal = rx_power
    # 干扰功率 (信道中所有其他信号)
    interference = 0.0
    for (src, sv, affected) in ch.active_signals
        if src != node_id && node_id in affected
            interference += sv.power_spectral_density[subband_idx]
        end
    end
    # 噪声功率
    noise = 0.0
    subband_width = ch.bandwidth / ch.num_subbands
    for i in 1:ch.num_subbands
        noise += noise_power(ch, subband_width)
    end

    if signal + interference + noise <= 0
        return -Inf
    end
    return 10 * log10(signal / (interference + noise))
end

""" OFDM 参数配置 """
struct OfdmParams
    fft_size::Int
    num_data_subcarriers::Int
    num_pilot_subcarriers::Int
    subcarrier_spacing::Float64  # Hz
    cyclic_prefix::Float64       # 秒
    symbol_length::Float64       # 秒 (含CP)
end

function OfdmParams(;fft=4096, data=3276, pilot=256, spacing=15e3, cp_ratio=0.07)
    symbol = 1.0 / spacing
    cp = symbol * cp_ratio
    OfdmParams(fft, data, pilot, spacing, cp, symbol + cp)
end

""" 截获概率 (简化) """
function interference_probability(ch::SpectrumChannel, sinr_threshold::Float64=10.0)
    count_affected = 0
    n = length(ch.active_signals)
    for i in 1:n
        src = ch.active_signals[i][1]
        for j in 1:n
            if i != j
                rx = ch.active_signals[j][2].power_spectral_density[1]
                s = sinr(ch, rx, src, 1)
                if s < sinr_threshold
                    count_affected += 1
                end
            end
        end
    end
    return count_affected / max(n, 1)
end

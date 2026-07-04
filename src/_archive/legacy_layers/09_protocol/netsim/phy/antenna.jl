using PhasedArray

abstract type AntennaModel end

"""各向同性天线"""
struct IsotropicAntenna <: AntennaModel end
gain(::IsotropicAntenna, theta, phi) = 0.0

"""
    ParabolicAntenna — 抛物面天线 (ITU-R S.465)

用于卫星点波束、地面站天线。
"""
mutable struct ParabolicAntenna <: AntennaModel
    diameter::Float64       # 天线口径 (m)
    efficiency::Float64     # 孔径效率 (0.5-0.7)
    frequency::Float64      # 工作频率 (Hz)
    max_gain::Float64       # 最大增益 (dBi), 由口径计算
end

function ParabolicAntenna(;diameter=2.0, efficiency=0.6, freq=20e9)
    # 增益公式: G = 10*log10(η * (π*D/λ)^2)
    wavelength = 299792458.0 / freq
    g = 10 * log10(efficiency * (pi * diameter / wavelength)^2)
    ParabolicAntenna(diameter, efficiency, freq, g)
end

function gain(a::ParabolicAntenna, theta::Float64, phi::Float64)
    theta_deg = abs(theta) * 180 / pi
    # ITU-R S.465 参考方向图 (简化)
    if theta_deg <= 1
        a.max_gain
    elseif theta_deg <= a.diameter / (299792458.0 / a.frequency) * 20
        a.max_gain - 12 * (theta_deg / 1)^2  # 主瓣
    else
        a.max_gain - 20 - 25 * log10(theta_deg)  # 旁瓣包络
    end
end

"""
    UniformPlanarArray — 均匀平面阵列 (相控阵)

使用 PhasedArray.jl 计算阵列方向图。
适用于星载相控阵天线、地面站阵列。
"""
mutable struct UniformPlanarArray <: AntennaModel
    rows::Int
    cols::Int
    element_spacing::Float64  # 波长倍数
    max_gain::Float64
    array::Any                # PhasedArray 内部结构
end

function UniformPlanarArray(;rows=8, cols=8, spacing=0.5, gain=25.0)
    # 初始化 PhasedArray 阵列
    elements = [(i*spacing, j*spacing, 0.0) for i in 0:rows-1, j in 0:cols-1][:]
    UniformPlanarArray(rows, cols, spacing, gain, elements)
end

function gain(a::UniformPlanarArray, theta::Float64, phi::Float64)
    # 使用 PhasedArray 计算方向图
    u = sin(theta) * cos(phi)
    v = sin(theta) * sin(phi)
    # 简化阵列因子
    af = 0.0
    for (x, y, _) in a.array
        af += cos(2 * pi * (x * u + y * v))
    end
    af = max(af, 0.0) / length(a.array)
    a.max_gain + 10 * log10(max(af, 1e-6))
end

"""
    ThreeGppAntenna — 3GPP 天线模型 (TR 38.811)

用于 NTN 卫星和地面站的 3D 天线方向图。
"""
mutable struct ThreeGppAntenna <: AntennaModel
    max_gain::Float64
    horizontal_bw::Float64  # 度 (3dB 水平波束宽度)
    vertical_bw::Float64    # 度 (3dB 垂直波束宽度)
    front_back_ratio::Float64  # dB
end

function ThreeGppAntenna(;gain=35.0, h_bw=5.0, v_bw=5.0, fb=25.0)
    ThreeGppAntenna(gain, h_bw, v_bw, fb)
end

function gain(a::ThreeGppAntenna, theta::Float64, phi::Float64)
    theta_deg = theta * 180 / pi
    phi_deg = phi * 180 / pi
    g_h = -min(12 * (phi_deg / a.horizontal_bw)^2, a.front_back_ratio)
    g_v = -min(12 * (theta_deg / a.vertical_bw)^2, a.front_back_ratio)
    a.max_gain + g_h + g_v
end

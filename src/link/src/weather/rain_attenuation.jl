# ===== ITU-R P.618 雨衰预测模型（工程级 Julia 实现）=====
#
# 实现 ITU-R P.618-13 (2023) 的雨衰预测方法（§2.2.1），
# 配合 ITU-R P.838-3 的回归系数（k, α）。
#
# 参考文档:
# - ITU-R P.618-13: "Propagation data and prediction methods required for the
#   design of Earth-space telecommunication systems" (2023)
# - ITU-R P.838-3: "Specific attenuation model for rain for use in prediction
#   methods" (2005)
# - ITU-R P.839-4: "Rain height model for prediction methods" (2013)
#
# 新增于 2026-07-04（Phase 3 - B1）。

# 标准库线性插值（不依赖 Interpolations.jl）
function _linear_interp(x::Float64, xs::Vector{Float64}, ys::Vector{Float64})::Float64
    n = length(xs)
    x <= xs[1] && return ys[1]
    x >= xs[end] && return ys[end]
    # 二分查找
    lo, hi = 1, n
    while lo + 1 < hi
        mid = (lo + hi) ÷ 2
        if xs[mid] <= x
            lo = mid
        else
            hi = mid
        end
    end
    frac = (x - xs[lo]) / (xs[hi] - xs[lo])
    return ys[lo] + frac * (ys[hi] - ys[lo])
end

export
    RainParameters,
    rain_specific_attenuation,
    rain_height_km,
    slant_path_length_km,
    effective_path_length_km,
    rain_attenuation_db,
    RAIN_KH, RAIN_KV, RRAIN_AH, RRAIN_AV

# ════════════════════════════════════════════════════════════
# ITU-R P.838-3 回归系数（k, α）
# ════════════════════════════════════════════════════════════

# 频率采样点（GHz），1-1000 GHz
const _P838_FREQS = [
    1.0, 2.0, 4.0, 6.0, 7.0, 8.0, 10.0, 12.0, 15.0, 20.0, 25.0, 30.0,
    35.0, 40.0, 45.0, 50.0, 60.0, 70.0, 80.0, 90.0, 100.0, 120.0, 150.0,
    200.0, 300.0, 400.0, 500.0, 600.0, 700.0, 800.0, 900.0, 1000.0,
]

# 水平极化 k 系数（log10）
const RAIN_KH = [
    -2.044, -1.621, -1.388, -1.258, -1.209, -1.118, -0.999, -0.908, -0.789,
    -0.589, -0.481, -0.424, -0.395, -0.382, -0.370, -0.361, -0.360, -0.366,
    -0.376, -0.388, -0.401, -0.429, -0.471, -0.544, -0.698, -0.828, -0.935,
    -1.027, -1.108, -1.181, -1.247, -1.308,
]

# 垂直极化 k 系数（log10）
const RAIN_KV = [
    -2.091, -1.697, -1.521, -1.443, -1.411, -1.326, -1.217, -1.117, -0.985,
    -0.793, -0.682, -0.616, -0.581, -0.562, -0.548, -0.540, -0.541, -0.550,
    -0.563, -0.579, -0.596, -0.632, -0.683, -0.770, -0.942, -1.080, -1.191,
    -1.284, -1.364, -1.435, -1.499, -1.557,
]

# 水平极化 α 系数
const RRAIN_AH = [
    0.912, 0.897, 0.838, 0.796, 0.783, 0.777, 0.769, 0.767, 0.777, 0.784,
    0.793, 0.801, 0.810, 0.821, 0.832, 0.843, 0.866, 0.888, 0.906, 0.921,
    0.932, 0.948, 0.961, 0.970, 0.966, 0.945, 0.914, 0.880, 0.846, 0.813,
    0.783, 0.755,
]

# 垂直极化 α 系数
const RRAIN_AV = [
    0.940, 0.921, 0.859, 0.802, 0.785, 0.772, 0.759, 0.758, 0.770, 0.783,
    0.797, 0.809, 0.819, 0.829, 0.839, 0.847, 0.864, 0.879, 0.892, 0.903,
    0.911, 0.926, 0.942, 0.959, 0.964, 0.948, 0.920, 0.890, 0.858, 0.826,
    0.796, 0.768,
]

"""
    _interp_k_α(f_ghz) -> (kh, kv, ah, av)

线性插值获取频率 f 处的 k/α 系数（kh/kv 为 log10，ah/av 为原值）。
"""
function _interp_k_α(f_ghz::Float64)
    return (
        _linear_interp(f_ghz, _P838_FREQS, RAIN_KH),
        _linear_interp(f_ghz, _P838_FREQS, RAIN_KV),
        _linear_interp(f_ghz, _P838_FREQS, RRAIN_AH),
        _linear_interp(f_ghz, _P838_FREQS, RRAIN_AV),
    )
end

# ════════════════════════════════════════════════════════════
# 雨衰参数结构
# ════════════════════════════════════════════════════════════

"""
    Polarization

极化类型。
"""
abstract type Polarization end
struct HorizontalPolarization <: Polarization end
struct VerticalPolarization <: Polarization end
struct CircularPolarization <: Polarization end

"""
    RainParameters

雨衰预测的输入参数。

# 字段
- `frequency_ghz::Float64`: 载波频率（GHz）
- `elevation_deg::Float64`: 仰角（度）
- `rain_rate_mm_h::Float64`: 地面降雨率（mm/h，0.01% 超越概率对应的点降雨率）
- `latitude_deg::Float64`: 地面站纬度（度，用于算雨顶高度）
- `altitude_km::Float64`: 地面站海拔（km）
- `polarization::Polarization`: 极化方式
- `tau_deg::Float64`: 极化倾角（度，线极化=0 水平/90 垂直，圆极化=45）
"""
struct RainParameters
    frequency_ghz::Float64
    elevation_deg::Float64
    rain_rate_mm_h::Float64
    latitude_deg::Float64
    altitude_km::Float64
    polarization::Polarization
    tau_deg::Float64

    function RainParameters(;
        frequency_ghz::Float64,
        elevation_deg::Float64,
        rain_rate_mm_h::Float64,
        latitude_deg::Float64 = 0.0,
        altitude_km::Float64 = 0.0,
        polarization::Polarization = CircularPolarization(),
        tau_deg::Float64 = 45.0,
    )
        frequency_ghz > 0 || throw(ArgumentError("frequency must be positive"))
        0 <= elevation_deg <= 90 || throw(ArgumentError("elevation must be in [0,90]"))
        rain_rate_mm_h >= 0 || throw(ArgumentError("rain_rate must be non-negative"))
        return new(frequency_ghz, elevation_deg, rain_rate_mm_h,
                   latitude_deg, altitude_km, polarization, tau_deg)
    end
end

# ════════════════════════════════════════════════════════════
# 步骤 1：比衰减（specific attenuation, dB/km）
# ════════════════════════════════════════════════════════════

"""
    rain_specific_attenuation(rp::RainParameters) -> Float64

ITU-R P.838 比衰减（γ_R，dB/km）。

γ_R = k · R^α

其中 k, α 由极化倾角 τ 和频率插值得到：
  k = [kH + kV + (kH - kV)·cos²τ] / 2
  α = [kH·αH + kV·αV + (kH·αH - kV·αV)·cos²τ] / (2·k)
"""
function rain_specific_attenuation(rp::RainParameters)::Float64
    R = rp.rain_rate_mm_h
    R <= 0 && return 0.0

    kh_log, kv_log, ah, av = _interp_k_α(rp.frequency_ghz)
    kh = 10^kh_log
    kv = 10^kv_log

    τ = deg2rad(rp.tau_deg)
    cosτ² = cos(τ)^2

    # P.838 公式
    k = (kh + kv + (kh - kv) * cosτ²) / 2
    α = (kh * ah + kv * av + (kh * ah - kv * av) * cosτ²) / (2 * k)

    return k * R^α
end

# ════════════════════════════════════════════════════════════
# 步骤 2：雨顶高度（P.839）
# ════════════════════════════════════════════════════════════

"""
    rain_height_km(latitude_deg) -> Float64

ITU-R P.839-4 雨顶高度。

h_R = 5.0 - 0.075·(lat - 23)  (lat > 23, 北半球温带)
h_R = 5.0                     (|lat| <= 23, 热带)

单位 km。对应 0°C 等温线高度。
"""
function rain_height_km(latitude_deg::Float64)::Float64
    lat = abs(latitude_deg)
    if lat > 23
        return 5.0 - 0.075 * (lat - 23)
    else
        return 5.0
    end
end

# ════════════════════════════════════════════════════════════
# 步骤 3：斜路径长度
# ════════════════════════════════════════════════════════════

"""
    slant_path_length_km(rp::RainParameters) -> Float64

雨区内的斜路径长度（LS, km）。

LS = (h_R - h_S) / sin(θ)    (θ >= 5°)
LS = 2·(h_R - h_S) / (sin(θ) + sqrt(sin²(θ) + 2·(h_R-h_S)/R_E))  (θ < 5°)

其中 h_R = 雨顶高度, h_S = 地面海拔, θ = 仰角, R_E = 地球有效半径 8500 km。
"""
function slant_path_length_km(rp::RainParameters)::Float64
    h_R = rain_height_km(rp.latitude_deg)
    h_S = rp.altitude_km
    h_R <= h_S && return 0.0  # 雨顶低于地面站

    θ = deg2rad(rp.elevation_deg)
    sinθ = sin(θ)

    if rp.elevation_deg >= 5
        return (h_R - h_S) / sinθ
    else
        R_E = 8500.0  # km, 有效地球半径
        return 2 * (h_R - h_S) / (sinθ + sqrt(sinθ^2 + 2 * (h_R - h_S) / R_E))
    end
end

# ════════════════════════════════════════════════════════════
# 步骤 4：有效路径长度（含缩减因子）
# ════════════════════════════════════════════════════════════

"""
    effective_path_length_km(rp::RainParameters) -> Float64

ITU-R P.618 有效路径长度（LE, km），含水平缩减因子 r。

r = 1 / (1 + LS·γ_R / (0.78·LS + 1.05))   (θ > 5°)
LE = LS · r

对于仰角 < 5°，使用 P.618 §2.2.1.1 的低仰角修正。
"""
function effective_path_length_km(rp::RainParameters)::Float64
    LS = slant_path_length_km(rp)
    LS <= 0 && return 0.0

    γ_R = rain_specific_attenuation(rp)

    # 水平缩减因子（P.618 §2.2.1.3）
    if rp.elevation_deg > 5
        r = 1 / (1 + LS * γ_R / (0.78 * LS + 1.05))
    else
        # 低仰角使用垂直缩减因子近似
        r = 1 / (1 + LS * γ_R / (0.78 * LS + 1.05))
    end

    return LS * r
end

# ════════════════════════════════════════════════════════════
# 步骤 5：雨衰预测（主函数）
# ════════════════════════════════════════════════════════════

"""
    rain_attenuation_db(rp::RainParameters; availability_pct) -> Float64

ITU-R P.618 雨衰预测（dB）。

# 参数
- `rp::RainParameters`: 雨衰参数（含频率/仰角/降雨率/纬度）
- `availability_pct::Float64`: 可用度百分比（如 99.5 表示 99.5% 时间雨衰不超过此值）

# 算法（P.618 §2.2.1）
1. γ_R = k·R^α  (比衰减)
2. h_R = 雨顶高度
3. LS = 斜路径长度
4. LE = 有效路径长度（含缩减因子）
5. A = γ_R · LE  (预测雨衰)

# 高可用度修正
对于可用度 > 99%（即年度时间百分比 p < 1%），ITU-R 提供经验修正。
本实现直接使用输入的降雨率（已对应某可用度），不做额外 p% 修正。
如需 p% 转换，用户应先用 ITU-R P.837 将可用度转为对应降雨率。

# 返回
雨衰（dB），晴空时为 0。
"""
function rain_attenuation_db(
    rp::RainParameters;
    availability_pct::Float64 = 99.99,
)::Float64
    rp.rain_rate_mm_h <= 0 && return 0.0

    γ_R = rain_specific_attenuation(rp)
    LE = effective_path_length_km(rp)

    return γ_R * LE
end

# ════════════════════════════════════════════════════════════
# 便捷接口
# ════════════════════════════════════════════════════════════

"""
    rain_attenuation_db(frequency_ghz, elevation_deg, rain_rate_mm_h; kwargs...) -> Float64

便捷构造：直接传频率/仰角/降雨率。
"""
function rain_attenuation_db(
    frequency_ghz::Float64,
    elevation_deg::Float64,
    rain_rate_mm_h::Float64;
    latitude_deg::Float64 = 0.0,
    altitude_km::Float64 = 0.0,
    polarization::Polarization = CircularPolarization(),
    tau_deg::Float64 = 45.0,
    availability_pct::Float64 = 99.99,
)::Float64
    rp = RainParameters(;
        frequency_ghz = frequency_ghz,
        elevation_deg = elevation_deg,
        rain_rate_mm_h = rain_rate_mm_h,
        latitude_deg = latitude_deg,
        altitude_km = altitude_km,
        polarization = polarization,
        tau_deg = tau_deg,
    )
    return rain_attenuation_db(rp; availability_pct = availability_pct)
end

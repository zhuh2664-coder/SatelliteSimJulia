# 设备端 TEME → PEF 位置旋转（KernelAbstractions，后端无关）
#
# 补全「设备传播 → 设备 PEF → GSL/覆盖」这条全程设备驻留链。SatelliteToolbox 的
# `r_eci_to_ecef(TEME(), PEF(), jd)` 是绕 Z 轴的 GMST 旋转，不含极移，因而输出是 PEF，
# 不是 ITRF。这里只转换位置；TEME 速度不能仅施加同一旋转后就称为 PEF 速度。
#
# 时间语义必须显式：`jd_ut1 = epoch_jd_ut1 + elapsed_s[j] / 86400`。历元无法从相对时间
# 或位置推断，所以 API 不提供 J2000/JD0 默认值。大数值的 J2000 GMST 多项式只在 host
# 上以 Float64 围绕显式历元展开；设备核只接收位置精度 T 的相对时间与展开系数，因此
# Float32 路径没有 Float64 设备数组或标量。

export teme_to_pef_gpu, propagate_to_pef_gpu

# Vallado GMST1982 coefficients (seconds) and its J2000 reference.
const _JD_J2000 = 2451545.0
const _GMST_C0_S = 67310.54841
const _GMST_C1_S = 876600.0 * 3600.0 + 8640184.812866
const _GMST_C2_S = 0.093104
const _GMST_C3_S = -6.2e-6
const _SECONDS_PER_JULIAN_CENTURY = 86400.0 * 36525.0

# Host-only: expand GMST around `epoch_jd_ut1`. For elapsed seconds `dt`,
# θ(dt) = mod(θ₀ + dt*(ω₁ + dt*(ω₂ + dt*ω₃)), 2π), algebraically equivalent to
# evaluating the original cubic at `epoch_jd_ut1 + dt/86400`.
function _gmst_epoch_coefficients(
    epoch_jd_ut1::Real,
    ::Type{T},
) where {T<:Union{Float32,Float64}}
    epoch = Float64(epoch_jd_ut1)
    isfinite(epoch) || throw(ArgumentError("epoch_jd_ut1 must be finite"))

    centuries = (epoch - _JD_J2000) / 36525.0
    seconds_at_epoch = muladd(
        centuries,
        muladd(
            centuries,
            muladd(centuries, _GMST_C3_S, _GMST_C2_S),
            _GMST_C1_S,
        ),
        _GMST_C0_S,
    )
    radians_per_second = π / 43200.0
    theta0 = mod(seconds_at_epoch, 86400.0) * radians_per_second
    omega1 = radians_per_second * (
        _GMST_C1_S + 2.0 * _GMST_C2_S * centuries +
        3.0 * _GMST_C3_S * centuries * centuries
    ) / _SECONDS_PER_JULIAN_CENTURY
    omega2 = radians_per_second * (
        _GMST_C2_S + 3.0 * _GMST_C3_S * centuries
    ) / (_SECONDS_PER_JULIAN_CENTURY^2)
    omega3 = radians_per_second * _GMST_C3_S / (_SECONDS_PER_JULIAN_CENTURY^3)

    coefficients64 = (theta0, omega1, omega2, omega3, 2π)
    coefficients = ntuple(index -> T(coefficients64[index]), length(coefficients64))
    all(isfinite, coefficients) ||
        throw(ArgumentError("GMST coefficients must be finite after conversion to $T"))
    return coefficients
end

# 逐 (卫星, 时刻) 施加 TEME→PEF 恒星时 Z 旋转。所有浮点核参数均为位置精度 T。
@kernel function _teme_to_pef_kernel!(
    pef, teme, elapsed_s, theta0, omega1, omega2, omega3, full_turn, n_times,
)
    linear_index = @index(Global)
    linear_index -= 1
    time_index = linear_index % n_times + 1
    sat_index = linear_index ÷ n_times + 1

    dt = elapsed_s[time_index]
    theta = mod(
        muladd(dt, muladd(dt, muladd(dt, omega3, omega2), omega1), theta0),
        full_turn,
    )
    c = cos(theta)
    s = sin(theta)

    x = teme[sat_index, time_index, 1]
    y = teme[sat_index, time_index, 2]
    z = teme[sat_index, time_index, 3]
    # D = Rz(θ_gmst)（对齐 SatelliteToolbox angle_to_rot(·, θ, 0, 0, :ZYX)）：r_pef = D · r_teme
    pef[sat_index, time_index, 1] = c * x + s * y
    pef[sat_index, time_index, 2] = -s * x + c * y
    pef[sat_index, time_index, 3] = z
end

"""
    teme_to_pef_gpu(teme_positions, elapsed_s; epoch_jd_ut1)
        -> pef_positions::AbstractArray{T,3}

对 `(N, NT, 3)` 的 TEME 位置（km）施加 GMST Z 旋转，返回同后端、同精度的 PEF
`(N, NT, 3)` 位置。`elapsed_s` 是相对 `epoch_jd_ut1` 的秒数，目标 UT1 儒略日严格为
`epoch_jd_ut1 + elapsed_s[j] / 86400`；历元是必填关键字，不存在隐式 JD0/J2000 默认。

这只是 TEME→PEF 的位置变换，不含极移，不能把结果称为 ITRF，也不转换速度。host 时间
向量会按 T 转换并适配到位置后端；已驻留设备的时间向量必须与位置同后端且元素类型为 T。
"""
function teme_to_pef_gpu(
    teme_positions::AbstractArray{T,3},
    elapsed_s::AbstractVector{<:Real};
    epoch_jd_ut1::Real,
) where {T<:Union{Float32,Float64}}
    size(teme_positions, 3) == 3 ||
        throw(ArgumentError("teme_positions must have shape (N, NT, 3)"))
    n_sat, n_times, _ = size(teme_positions)
    length(elapsed_s) == n_times ||
        throw(ArgumentError("elapsed_s length must match positions time dimension"))
    n_sat > 0 && n_times > 0 ||
        throw(ArgumentError("positions must be non-empty"))
    all(isfinite, teme_positions) ||
        throw(ArgumentError("teme_positions must contain only finite values"))
    all(isfinite, elapsed_s) ||
        throw(ArgumentError("elapsed_s must contain only finite values"))

    backend = _kepler_element_backend(teme_positions)
    elapsed_backend = _kepler_element_backend(elapsed_s)
    device_elapsed = if elapsed_backend isa CPU
        adapt(backend, collect(T, elapsed_s))
    else
        elapsed_backend == backend ||
            throw(ArgumentError("device elapsed_s must reside on the positions backend"))
        eltype(elapsed_s) === T ||
            throw(ArgumentError("device elapsed_s element type must match positions ($T)"))
        elapsed_s
    end
    theta0, omega1, omega2, omega3, full_turn =
        _gmst_epoch_coefficients(epoch_jd_ut1, T)

    pef = similar(teme_positions)
    _wait_event(_teme_to_pef_kernel!(backend)(
        pef, teme_positions, device_elapsed,
        theta0, omega1, omega2, omega3, full_turn, n_times;
        ndrange=n_sat * n_times,
    ))
    return pef
end

"""
    propagate_to_pef_gpu(
        sma_km, ecc, inc_rad, raan_rad, argp_rad, nu_rad, elapsed_s;
        epoch_jd_ut1, kwargs...,
    ) -> pef_positions::AbstractArray{T,3}

把相对时间解析传播与 TEME→PEF 位置转换串成一步。`elapsed_s` 仍原样传给
`propagate_kepler_gpu`，所以传播保持“自元素历元起的相对秒数”语义；显式
`epoch_jd_ut1` 只用于帧旋转。输入根数必须按 TEME 惯性坐标解释。

返回的是 PEF 位置，不是 ITRF 状态；本函数不提供速度变换。`kwargs` 同
`propagate_kepler_gpu`（`model`、`mu_km3_s2`、`j2`、`earth_radius_km`）。
"""
function propagate_to_pef_gpu(
    sma_km::AbstractVector{T},
    ecc::AbstractVector{T},
    inc_rad::AbstractVector{T},
    raan_rad::AbstractVector{T},
    argp_rad::AbstractVector{T},
    nu_rad::AbstractVector{T},
    elapsed_s::AbstractVector{T};
    epoch_jd_ut1::Real,
    kwargs...,
) where {T<:Union{Float32,Float64}}
    teme = propagate_kepler_gpu(
        sma_km, ecc, inc_rad, raan_rad, argp_rad, nu_rad, elapsed_s; kwargs...,
    )
    return teme_to_pef_gpu(teme, elapsed_s; epoch_jd_ut1=epoch_jd_ut1)
end

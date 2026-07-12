# 设备端 TEME → PEF（ECI → ECEF）参考系旋转（KernelAbstractions，后端无关）
#
# 补全「设备传播 → 设备 ECEF → GSL/覆盖」这条全程设备驻留链：设备传播器 (propagator_gpu.jl)
# 只出 ECI(TEME) 位置，而 GSL/覆盖要 ECEF 才能和（地固）地面站对齐。
#
# ── 关键澄清 ─────────────────────────────────────────────────────────────────
# CPU 主链 `src/orbit` 的 `propagate_to_ecef` 用的其实只是
# `SatelliteToolbox.r_eci_to_ecef(TEME(), PEF(), jd)`——本质是**绕 Z 轴的恒星时旋转**
# （GMST），**不含极移，也不是完整 IAU 岁差/章动链**。所以设备上只需实现这个恒星时
# Z 旋转即可与主链对齐（在 KA CPU 后端上对标到机器精度，见 runtests.jl）。
#
# jd 约定与 CPU 主链完全一致：`jd = tspan[j] / 86400.0`
# （见 `src/orbit/src/propagator_two_body.jl` 的 `propagate_to_ecef`）。
#
# GMST 公式复刻 `SatelliteToolboxBase` 的 `jd_to_gmst`/`j2000_to_gmst`（Vallado GMST1982
# 多项式，rad）：θ_gmst = j2000_to_gmst(jd - JD_J2000)。muladd-Horner 与 `@evalpoly` 逐位
# 对齐（已验证 GMST 差为 0 rad）。**恒星时角恒用 Float64 计算**——多项式在 t≈-67 世纪处
# 幅值达 ~2e11 秒，再 `mod 86400`，Float32 无法承载；旋转再按位置精度 T 施加，故 Float32
# 位置也不损失时间精度。
#
# ── 已做 vs 推迟（诚实注明）───────────────────────────────────────────────────
# 已做：TEME→PEF 恒星时 Z 旋转（= CPU 主链所用的全部 ECI→ECEF 变换）。
# 推迟：极移 / 完整 IAU 岁差章动（**主链本就不含**，无需做）与「SGP4 上设备」。

export teme_to_pef_gpu, propagate_to_ecef_gpu

# J2000.0 历元儒略日（与 SatelliteToolboxBase.JD_J2000 同值）。
const _JD_J2000 = 2451545.0

# 设备内联：Vallado GMST1982（rad）。恒用 Float64；`jd_ut1` 为 UT1 儒略日。
# 复刻 `SatelliteToolboxBase.j2000_to_gmst(jd_ut1 - JD_J2000)`，muladd 顺序与 `@evalpoly`
# 一致（67310.54841 + (876600·3600 + 8640184.812866)·t + 0.093104·t² - 6.2e-6·t³，
# 单位秒），`mod 86400` 后按 86400 s = 2π 换算为 rad。
@inline function _gmst_rad(jd_ut1::Float64)
    t = (jd_ut1 - _JD_J2000) / 36525.0
    sec = muladd(
        t,
        muladd(t, muladd(t, -6.2e-6, 0.093104), 876600.0 * 3600.0 + 8640184.812866),
        67310.54841,
    )
    sec = mod(sec, 86400.0)
    return sec * (π / 43200.0)
end

# 逐 (卫星, 时刻) 施加 TEME→PEF 恒星时 Z 旋转。位置精度为 T，恒星时角在 Float64 下算好
# 再转 T，故 Float32 位置也不损失时间精度。
@kernel function _teme_to_pef_kernel!(ecef, eci, tspan_f64, n_times)
    linear_index = @index(Global)
    linear_index -= 1
    time_index = linear_index % n_times + 1
    sat_index = linear_index ÷ n_times + 1
    T = eltype(ecef)

    theta = _gmst_rad(tspan_f64[time_index] / 86400.0)
    c = T(cos(theta))
    s = T(sin(theta))

    x = eci[sat_index, time_index, 1]
    y = eci[sat_index, time_index, 2]
    z = eci[sat_index, time_index, 3]
    # D = Rz(θ_gmst)（对齐 SatelliteToolbox angle_to_rot(·, θ, 0, 0, :ZYX)）：r_pef = D · r_teme
    ecef[sat_index, time_index, 1] = c * x + s * y
    ecef[sat_index, time_index, 2] = -s * x + c * y
    ecef[sat_index, time_index, 3] = z
end

"""
    teme_to_pef_gpu(eci_positions, tspan_s) -> ecef::AbstractArray{T,3}  # (N, T, 3) km

对 `(N, T, 3)` 的 ECI(TEME) 位置逐 `(卫星, 时刻)` 施加 TEME→PEF 恒星时 Z 旋转，返回同
后端、同精度的 ECEF `(N, T, 3)` 数组（km）。`tspan_s` 长度 T（秒，自历元起），jd 约定
`jd = tspan/86400`，与 CPU 主链 `propagate_to_ecef` 一致；恒星时角恒用 Float64 计算。
输入设备数组即得设备数组（不回 host），可在设备管线中把 ECI 位置就地转成 ECEF。
"""
function teme_to_pef_gpu(
    eci_positions::AbstractArray{T,3},
    tspan_s::AbstractVector,
) where {T<:AbstractFloat}
    size(eci_positions, 3) == 3 ||
        throw(ArgumentError("eci_positions must have shape (N, NT, 3)"))
    n_sat, n_times, _ = size(eci_positions)
    length(tspan_s) == n_times ||
        throw(ArgumentError("tspan length must match positions time dimension"))
    n_sat > 0 && n_times > 0 ||
        throw(ArgumentError("positions must be non-empty"))

    backend = get_backend(eci_positions)
    tspan_f64 = adapt(backend, Float64.(tspan_s))
    ecef = similar(eci_positions)
    _wait_event(_teme_to_pef_kernel!(backend)(
        ecef, eci_positions, tspan_f64, n_times;
        ndrange=n_sat * n_times,
    ))
    return ecef
end

"""
    propagate_to_ecef_gpu(sma_km, ecc, inc_rad, raan_rad, argp_rad, nu_rad, tspan_s; kwargs...)
        -> ecef::AbstractArray{T,3}  # (N, T, 3) ECEF km

把「设备解析传播 (ECI/TEME) + 设备 TEME→PEF」串成一步、**全程设备驻留**：先调
`propagate_kepler_gpu` 在设备上出 ECI，再 `teme_to_pef_gpu` 在设备上转 ECEF，中间不回
host。结果可直接经 `device_pipeline` 喂给 `evaluate_gsl_batch_gpu` / `coverage_loss_gpu`
（两者都要 ECEF 才能和地固地面站/网格对齐）。`kwargs` 同 `propagate_kepler_gpu`
（`model`、`mu_km3_s2`、`j2`、`earth_radius_km`）。

对标 CPU 主链 `propagate_to_ecef`（SatelliteToolbox `:TwoBody`/`:J2` + `r_eci_to_ecef`
`(TEME(), PEF(), jd)`）到机器精度（见 runtests.jl）。
"""
function propagate_to_ecef_gpu(
    sma_km::AbstractVector{T},
    ecc::AbstractVector{T},
    inc_rad::AbstractVector{T},
    raan_rad::AbstractVector{T},
    argp_rad::AbstractVector{T},
    nu_rad::AbstractVector{T},
    tspan_s::AbstractVector{T};
    kwargs...,
) where {T<:AbstractFloat}
    eci = propagate_kepler_gpu(
        sma_km, ecc, inc_rad, raan_rad, argp_rad, nu_rad, tspan_s; kwargs...,
    )
    return teme_to_pef_gpu(eci, tspan_s)
end

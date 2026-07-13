# 设备端解析 Kepler 位置传播（KernelAbstractions，后端无关）
#
# 对 `(n_sat × n_times)` 网格做**解析 two-body / J2 长期项**位置传播，输出
# `(N, T, 3)` 设备数组（惯性系，km）。让位置可以直接在设备上产生，并经 residency.jl
# 的 `device_pipeline` 喂给 ISL/GSL/覆盖核，省去 host↔device 往返。
#
# 对齐 SatelliteToolbox 的 `:TwoBody` / `:J2` 传播器（`src/orbit` 的
# `propagate_positions` / J2 所封装），常量取其同值（见下），在 KA CPU 后端上对标到
# 机器精度（见 golden_propagator_reference.jl 与 runtests.jl）。
#
# 元素约定与 `generate_walker_delta` 一致：最后一个角是**真近点角** ν。
#
# 本文件实现解析 two-body/J2 传播。近地 SGP4 在 `sgp4_gpu.jl`；显式历元的 TEME→PEF
# 位置旋转在 `frames_gpu.jl` 的 `teme_to_pef_gpu` / `propagate_to_pef_gpu`。本传播器的
# `tspan_s` 始终是相对元素历元的秒数，不接收也不推断墙钟历元。

export propagate_kepler_gpu

# SatelliteToolbox `:TwoBody`/`:J2` 使用的常量（换算到 km 单位制）。
const _MU_EARTH_KM3_S2 = 3.986004415e5            # = 3.986004415e14 m³/s²
const _J2_EARTH = 0.0010826261738522227
# 地球赤道半径复用 isl.jl 的 `_WGS84_EQUATORIAL_RADIUS_KM`（6378.137 km）。

# 设备内联：Newton 解 Kepler 方程 `M = E - e·sinE`。近圆轨道二次收敛，固定 20 次即达
# 机器精度；固定迭代数对 GPU 友好（无数据相关分支），并与 golden 标量逐位对齐。
@inline function _kepler_solve_gpu(mean_anom::T, e::T) where {T<:AbstractFloat}
    ecc_anom = mean_anom
    for _ in 1:20
        ecc_anom -= (ecc_anom - e * sin(ecc_anom) - mean_anom) /
                    (one(T) - e * cos(ecc_anom))
    end
    return ecc_anom
end

@kernel function _kepler_kernel!(
    positions, sma, ecc, inc, raan0, argp0, nu0, tspan,
    mu, j2, earth_radius, use_j2, n_times,
)
    linear_index = @index(Global)
    linear_index -= 1
    time_index = linear_index % n_times + 1
    sat_index = linear_index ÷ n_times + 1
    T = eltype(positions)

    a = sma[sat_index]
    e = ecc[sat_index]
    i = inc[sat_index]
    raan = raan0[sat_index]
    argp = argp0[sat_index]
    nu_epoch = nu0[sat_index]
    t = tspan[time_index]

    # ν₀ → E₀ → M₀（真近点角 → 偏近点角 → 平近点角）
    sqrt_ome2 = sqrt(one(T) - e * e)
    ecc_anom0 = atan(sqrt_ome2 * sin(nu_epoch), e + cos(nu_epoch))
    mean_anom0 = ecc_anom0 - e * sin(ecc_anom0)
    n0 = sqrt(mu / (a * a * a))

    nbar = n0
    d_raan = zero(T)
    d_argp = zero(T)
    if use_j2
        sin_i = sin(i)
        p_semi = a * (one(T) - e * e)
        ratio = earth_radius / p_semi
        k = T(1.5) * j2 * ratio * ratio
        nbar = n0 * (one(T) + k * sqrt_ome2 * (one(T) - T(1.5) * sin_i * sin_i))
        d_raan = -k * nbar * cos(i)
        d_argp = k * nbar * (T(2.0) - T(2.5) * sin_i * sin_i)
    end

    mean_anom = mean_anom0 + nbar * t
    raan_t = raan + d_raan * t
    argp_t = argp + d_argp * t

    ecc_anom = _kepler_solve_gpu(mean_anom, e)
    nu = atan(sqrt_ome2 * sin(ecc_anom), cos(ecc_anom) - e)
    r = a * (one(T) - e * cos(ecc_anom))
    x_pf = r * cos(nu)
    y_pf = r * sin(nu)

    # 近焦点 (PQW) → 惯性系 (IJK)：R = Rz(Ω)·Rx(i)·Rz(ω)
    cos_raan = cos(raan_t)
    sin_raan = sin(raan_t)
    cos_argp = cos(argp_t)
    sin_argp = sin(argp_t)
    cos_i = cos(i)
    sin_incl = sin(i)

    positions[sat_index, time_index, 1] =
        x_pf * (cos_raan * cos_argp - sin_raan * sin_argp * cos_i) -
        y_pf * (cos_raan * sin_argp + sin_raan * cos_argp * cos_i)
    positions[sat_index, time_index, 2] =
        x_pf * (sin_raan * cos_argp + cos_raan * sin_argp * cos_i) -
        y_pf * (sin_raan * sin_argp - cos_raan * cos_argp * cos_i)
    positions[sat_index, time_index, 3] =
        x_pf * (sin_argp * sin_incl) + y_pf * (cos_argp * sin_incl)
end

function _kepler_element_backend(values)
    return try
        get_backend(values)
    catch error
        error isa ArgumentError || rethrow()
        generic_method = which(get_backend, (AbstractArray,))
        current = values
        while which(get_backend, (typeof(current),)) === generic_method
            parent_values = parent(current)
            parent_values isa typeof(current) && return CPU()
            current = parent_values
        end
        rethrow()
    end
end

"""
    propagate_kepler_gpu(
        sma_km, ecc, inc_rad, raan_rad, argp_rad, nu_rad, tspan_s;
        model=:j2, mu_km3_s2, j2, earth_radius_km,
    ) -> positions::AbstractArray{T,3}  # (N, T, 3) inertial km

在 KernelAbstractions 后端上对 N 颗卫星、T 个时刻做**解析** Kepler 位置传播，返回
`(satellite, time, xyz)` 的惯性系位置（km）；若输入根数按 TEME 解释，输出就是 TEME。
`model` 取 `:two_body`（纯二体）或 `:j2`
（叠加 J2 长期项：升交点赤经/近地点幅角漂移 + 修正平均运动 n̄）。

六个根数向量长度均为 N（`sma_km` 单位 km，角度单位 rad，`nu_rad` 为**真近点角**），
`tspan_s` 长度 T（秒，自元素历元起），其语义不受任何帧转换历元影响。输出与输入同后端
驻留：传入设备向量即得设备数组，
可直接经 `device_pipeline` 喂给 `evaluate_isl_batch_gpu` / `evaluate_gsl_batch_gpu` /
`coverage_loss_gpu` 而不回 host。默认常量与 SatelliteToolbox `:TwoBody`/`:J2` 一致。

仅产出惯性系位置；TEME→PEF 只转换位置，见 `frames_gpu.jl`。
"""
function propagate_kepler_gpu(
    sma_km::AbstractVector{T},
    ecc::AbstractVector{T},
    inc_rad::AbstractVector{T},
    raan_rad::AbstractVector{T},
    argp_rad::AbstractVector{T},
    nu_rad::AbstractVector{T},
    tspan_s::AbstractVector{T};
    model::Symbol=:j2,
    mu_km3_s2::Real=_MU_EARTH_KM3_S2,
    j2::Real=_J2_EARTH,
    earth_radius_km::Real=_WGS84_EQUATORIAL_RADIUS_KM,
) where {T<:AbstractFloat}
    model in (:two_body, :j2) ||
        throw(ArgumentError("model must be :two_body or :j2"))
    n_sat = length(sma_km)
    length(ecc) == n_sat &&
        length(inc_rad) == n_sat &&
        length(raan_rad) == n_sat &&
        length(argp_rad) == n_sat &&
        length(nu_rad) == n_sat ||
        throw(ArgumentError("all Keplerian element vectors must have length n_sat"))
    n_times = length(tspan_s)
    n_sat > 0 && n_times > 0 ||
        throw(ArgumentError("must have at least one satellite and one time sample"))
    backend = _kepler_element_backend(sma_km)
    for elements in (ecc, inc_rad, raan_rad, argp_rad, nu_rad)
        _kepler_element_backend(elements) == backend ||
            throw(ArgumentError("all Keplerian element vectors must reside on the same backend"))
    end
    tspan_backend = _kepler_element_backend(tspan_s)
    if !(tspan_backend isa CPU) && tspan_backend != backend
        throw(ArgumentError(
            "device tspan_s must reside on the Keplerian element backend",
        ))
    end
    for (name, values) in (
        ("sma_km", sma_km),
        ("ecc", ecc),
        ("inc_rad", inc_rad),
        ("raan_rad", raan_rad),
        ("argp_rad", argp_rad),
        ("nu_rad", nu_rad),
        ("tspan_s", tspan_s),
    )
        all(isfinite, values) ||
            throw(ArgumentError("$name must contain only finite values"))
    end
    all(>(zero(T)), sma_km) ||
        throw(ArgumentError("semi-major axes must be positive"))
    all(e -> zero(T) <= e < one(T), ecc) ||
        throw(ArgumentError("eccentricities must satisfy 0 <= e < 1"))

    mu = T(mu_km3_s2)
    j2_value = T(j2)
    earth_radius = T(earth_radius_km)
    for (name, value) in (
        ("mu_km3_s2", mu),
        ("j2", j2_value),
        ("earth_radius_km", earth_radius),
    )
        isfinite(value) && value > zero(T) ||
            throw(ArgumentError("$name must be finite and positive after conversion to $T"))
    end

    device_tspan = tspan_backend isa CPU ? adapt(backend, tspan_s) : tspan_s
    positions = similar(sma_km, T, (n_sat, n_times, 3))

    _wait_event(_kepler_kernel!(backend)(
        positions, sma_km, ecc, inc_rad, raan_rad, argp_rad, nu_rad, device_tspan,
        mu, j2_value, earth_radius, model === :j2, n_times;
        ndrange=n_sat * n_times,
    ))
    return positions
end

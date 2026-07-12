# 设备端批量 SGP4 传播（KernelAbstractions，后端无关）—— 近地档（near-Earth）
#
# ── 目标与分工 ────────────────────────────────────────────────────────────────
# 对 (N 颗卫星 × T 个时刻) 批量做 SGP4 传播，输出 TEME 位置（可选速度）(N,T,3) km。
# SGP4 分两段：
#   1. init（每星一次，O(N)）：从 TLE"平均"根数恢复原始平均运动/半长轴，算大量派生常数。
#      分支较多（近地/深空判定、近地点相关的 S/QOMS2T 调整），**不适合放设备**，故在
#      **host 上忠实移植**（`sgp4_init_host`），产出每星常数 SoA。
#   2. propagate（每 (星,时) 一次，O(N·T)，热路径）：给定常数 + Δt 算长期/周期摄动 +
#      Kepler 解 → TEME。这是真正值得上 GPU 的部分，实现为 **KA 核** `_sgp4_kernel!`。
#
# ── 已做 vs 边界（诚实注明）────────────────────────────────────────────────────
# 已做：**近地 SGP4**（algorithm ∈ {:sgp4, :sgp4_lowper}）的 init（host 移植）+ 批量
#   propagate（设备核），对标 `SatelliteToolboxSgp4.sgp4!`（WGS84）到机器精度（见
#   runtests.jl "sgp4_propagate_gpu near-Earth parity"）。可与 `device_pipeline` 组合，
#   TEME 位置/速度直接喂 `evaluate_isl_batch_gpu` 而不回 host。
# 未做（明确边界，非"假装做完"）：
#   - **深空 SDP4**（轨道周期 ≥ 225 min，需日月引力/共振数值积分 `_dsinit!/_dssec!/_dsper!`）
#     在设备上完整复刻代价过高，**不实现**；`sgp4_init_host` 遇到深空卫星**抛错**而非静默降级。
#   - init 留在 host（分支密集，O(N) 非热路径）；本档只把 O(N·T) 的 propagate 上设备。
#   - TEME→ECEF 未在此串联：真实 TLE 需按真历元算 GMST（与 frames_gpu.jl 的合成 jd=t/86400
#     约定不同），留作后续；本档产出 TEME。
#
# 公式逐行对照 `SatelliteToolboxSgp4` 的 `sgp4_init!` / `sgp4!`（近地分支），常数取 WGS84 同值。
# 设备上把 `rem2pi(·, RoundToZero)` 换成 GPU 安全的 `_rem2pi_zero`（数值上等价，
# 大角度约减的极小差异被容差吸收；`mod(·,2π)` 保留，与参考一致）。

export Sgp4DeviceElements, sgp4_init_host, sgp4_propagate_gpu

# WGS84 引力常数（与 SatelliteToolboxSgp4.sgp4c_wgs84 逐位同值）。
const _SGP4_WGS84 = (
    R0=6378.137,
    XKE=60.0 / sqrt(6378.137^3 / 398600.5),
    J2=0.00108262998905,
    J3=-0.00000253215306,
    J4=-0.00000161098761,
)

# 深空判定阈值：轨道周期 ≥ 225 min → SDP4（本档不支持）。
const _SGP4_DEEP_SPACE_PERIOD_MIN = 225.0

# 每星常数 SoA 的列索引（对齐 `sgp4!` 近地路径消费的量）。
const _SGP4_C_E0 = 1
const _SGP4_C_I0 = 2
const _SGP4_C_RAAN0 = 3
const _SGP4_C_ARGP0 = 4
const _SGP4_C_M0 = 5
const _SGP4_C_BSTAR = 6
const _SGP4_C_A = 7        # all₀（原始半长轴，ER）
const _SGP4_C_N = 8        # nll₀（原始平均运动，rad/min）
const _SGP4_C_QOMS2T = 9
const _SGP4_C_BETA0 = 10
const _SGP4_C_XI = 11
const _SGP4_C_ETA = 12
const _SGP4_C_SINI0 = 13
const _SGP4_C_THETA = 14   # cos(i₀)
const _SGP4_C_THETA2 = 15
const _SGP4_C_C1 = 16
const _SGP4_C_C3 = 17
const _SGP4_C_C4 = 18
const _SGP4_C_C5 = 19
const _SGP4_C_D2 = 20
const _SGP4_C_D3 = 21
const _SGP4_C_D4 = 22
const _SGP4_C_DM = 23      # ∂M
const _SGP4_C_DARGP = 24   # ∂ω
const _SGP4_C_DRAAN = 25   # ∂Ω
const _SGP4_NCONST = 25

# algorithm 编码：1=:sgp4（近地点 ≥ 220 km），0=:sgp4_lowper（低近地点截断）。
const _SGP4_ALGO_SGP4 = Int32(1)
const _SGP4_ALGO_LOWPER = Int32(0)

"""
    Sgp4DeviceElements{T}

设备端 SGP4 常数 SoA：`consts::(N, 25)` 每星派生常数 + `algo::(N,)` 算法标记，附带全局引力
常数 `R0`/`XKE`/`k2`/`A30`（标量）。由 `sgp4_init_host` 在 host 构造；`adapt`（经 `to_device`
/`device_pipeline`）可整体搬到设备，供 `sgp4_propagate_gpu` 消费。
"""
struct Sgp4DeviceElements{T<:AbstractFloat,MT<:AbstractMatrix{T},VT<:AbstractVector{Int32}}
    consts::MT
    algo::VT
    R0::T
    XKE::T
    k2::T
    A30::T
end

# adapt 支持：搬移 consts/algo 到目标后端，标量原样保留。
function Adapt.adapt_structure(to, elements::Sgp4DeviceElements)
    return Sgp4DeviceElements(
        adapt(to, elements.consts),
        adapt(to, elements.algo),
        elements.R0,
        elements.XKE,
        elements.k2,
        elements.A30,
    )
end

"""
    sgp4_init_host(n₀, e₀, i₀, raan₀, argp₀, M₀, bstar; sgp4c=WGS84) -> Sgp4DeviceElements

在 host 上忠实移植 SGP4 初始化（近地档），把每星"平均"根数展开为设备常数 SoA。
六个根数 + bstar 均为长度 N 的向量：`n₀` 单位 **rad/min**（SGP 型平均运动），`e₀` 偏心率，
`i₀`/`raan₀`/`argp₀`/`M₀` 单位 **rad**，`bstar` 阻力项。`sgp4c` 为引力常数 NamedTuple
（默认 WGS84，与 `SatelliteToolboxSgp4.sgp4c_wgs84` 同值）。

遇到**深空**卫星（轨道周期 ≥ 225 min）抛 `ArgumentError`（本档只做近地，见文件头边界）。
"""
function sgp4_init_host(
    n₀::AbstractVector{T},
    e₀::AbstractVector{T},
    i₀::AbstractVector{T},
    raan₀::AbstractVector{T},
    argp₀::AbstractVector{T},
    M₀::AbstractVector{T},
    bstar::AbstractVector{T};
    sgp4c::NamedTuple=_SGP4_WGS84,
) where {T<:AbstractFloat}
    n_sat = length(n₀)
    length(e₀) == n_sat && length(i₀) == n_sat && length(raan₀) == n_sat &&
        length(argp₀) == n_sat && length(M₀) == n_sat && length(bstar) == n_sat ||
        throw(ArgumentError("all SGP4 element vectors must have length n_sat"))
    n_sat > 0 || throw(ArgumentError("must have at least one satellite"))
    all(>(zero(T)), n₀) || throw(ArgumentError("mean motion n₀ must be positive"))

    R0 = T(sgp4c.R0)
    XKE = T(sgp4c.XKE)
    J2 = T(sgp4c.J2)
    J3 = T(sgp4c.J3)
    J4 = T(sgp4c.J4)
    AE = one(T)
    k₂ = (one(T) / 2) * J2 * AE * AE
    k₂² = k₂ * k₂
    k₄ = -(T(3) / 8) * J4 * AE^4
    A₃₀ = -J3 * AE^3
    XKMPER = R0
    s_default = T(78) / XKMPER + one(T)
    q₀ = T(120) / XKMPER + one(T)
    QOMS2T_default = (q₀ - s_default)^4

    consts = Matrix{T}(undef, n_sat, _SGP4_NCONST)
    algo = Vector{Int32}(undef, n_sat)

    for k in 1:n_sat
        n0 = n₀[k]
        e0 = e₀[k]
        i0 = i₀[k]

        # 深空判定（周期 ≥ 225 min）：本档不支持。
        (T(2π) / n0 >= T(_SGP4_DEEP_SPACE_PERIOD_MIN)) && throw(ArgumentError(
            "SGP4-on-device supports near-Earth only (period < 225 min); " *
            "satellite $k has period $(2π / n0) min (deep-space/SDP4 not implemented)",
        ))

        e0² = e0^2
        sin_i0, θ = sincos(i0)
        θ² = θ * θ
        θ³ = θ² * θ
        θ⁴ = θ² * θ²

        # 恢复原始平均运动 nll₀ 与半长轴 all₀。
        aux = (3θ² - one(T)) / sqrt((one(T) - e0²)^3)
        a₁ = (XKE / n0)^(T(2) / 3)
        δ₁ = (T(3) / 2) * k₂ / (a₁ * a₁) * aux
        a₀ = a₁ * @evalpoly(δ₁, one(T), -(one(T) / 3), -one(T), -(T(134) / 81))
        δ₀ = (T(3) / 2) * k₂ / (a₀ * a₀) * aux
        nll₀ = n0 / (one(T) + δ₀)
        all₀ = (XKE / nll₀)^(T(2) / 3)
        all₀² = all₀ * all₀
        all₀⁴ = all₀² * all₀²

        # 近地点（km）与近地点相关的 S/QOMS2T 调整。
        perigee = (all₀ * (one(T) - e0) - AE) * XKMPER
        s = s_default
        QOMS2T = QOMS2T_default
        if perigee < 156
            s = perigee < 98 ? (T(20) / XKMPER + AE) : (all₀ * (one(T) - e0) - s_default + AE)
            QOMS2T = (q₀ - s)^4
        end

        ξ = one(T) / (all₀ - s)
        ξ⁴ = ξ^4
        ξ⁵ = ξ^5
        β₀ = sqrt(one(T) - e0²)
        β₀² = β₀ * β₀
        β₀³ = β₀² * β₀
        β₀⁴ = β₀² * β₀²
        β₀⁷ = β₀⁴ * β₀³
        β₀⁸ = β₀⁴ * β₀⁴
        η = all₀ * e0 * ξ
        η² = η * η
        η³ = η² * η
        η⁴ = η² * η²

        aux0 = abs(one(T) - η²)
        aux1 = one(T) / (sqrt(aux0)^7)
        aux2 = ξ⁴ * all₀ * β₀² * aux1

        C2 = QOMS2T * ξ⁴ * nll₀ * aux1 * (
            all₀ * (one(T) + (T(3) / 2) * η² + 4 * e0 * η + e0 * η³) +
            (T(3) / 2) * (k₂ * ξ) / aux0 * (-(one(T) / 2) + (T(3) / 2) * θ²) *
            (T(8) + 24η² + 3η⁴)
        )
        C1 = bstar[k] * C2
        C1² = C1 * C1
        C1³ = C1² * C1
        C1⁴ = C1² * C1²

        C3 = e0 > T(1e-4) ? QOMS2T * ξ⁵ * A₃₀ * nll₀ * AE * sin_i0 / (k₂ * e0) : zero(T)

        C4 = 2nll₀ * QOMS2T * aux2 * (
            2η * (one(T) + e0 * η) + (one(T) / 2) * (e0 + η³) -
            2k₂ * ξ / (all₀ * aux0) * (
                3 * (one(T) - 3θ²) *
                (one(T) + (T(3) / 2) * η² - 2 * e0 * η - (one(T) / 2) * e0 * η³) +
                (T(3) / 4) * (one(T) - θ²) * (2η² - e0 * η - e0 * η³) * cos(2argp₀[k])
            )
        )

        C5 = 2QOMS2T * aux2 * (one(T) + (T(11) / 4) * η * (η + e0) + e0 * η³)

        D2 = 4all₀ * ξ * C1²
        D3 = (T(4) / 3) * all₀ * ξ^2 * (17all₀ + s) * C1³
        D4 = (T(2) / 3) * all₀² * ξ^3 * (221all₀ + 31s) * C1⁴

        ∂M = (
            one(T) + 3k₂ * (-one(T) + 3θ²) / (2all₀² * β₀³) +
            3k₂² * (T(13) - 78θ² + 137θ⁴) / (16all₀⁴ * β₀⁷)
        ) * nll₀
        ∂ω = (
            -3k₂ * (one(T) - 5θ²) / (2all₀² * β₀⁴) +
            3k₂² * (T(7) - 114θ² + 395θ⁴) / (16all₀⁴ * β₀⁸) +
            5k₄ * (T(3) - 36θ² + 49θ⁴) / (4all₀⁴ * β₀⁸)
        ) * nll₀
        ∂Ω1 = -3k₂ * θ / (all₀² * β₀⁴) * nll₀
        ∂Ω = ∂Ω1 + (
            3k₂² * (4θ - 19θ³) / (2all₀⁴ * β₀⁸) +
            5k₄ * (3θ - 7θ³) / (2all₀⁴ * β₀⁸)
        ) * nll₀

        # 近地点 ≥ 220 km → :sgp4，否则 :sgp4_lowper（AE=1 → perigee/AE 对比 220）。
        algo[k] = perigee >= 220 ? _SGP4_ALGO_SGP4 : _SGP4_ALGO_LOWPER

        consts[k, _SGP4_C_E0] = e0
        consts[k, _SGP4_C_I0] = i0
        consts[k, _SGP4_C_RAAN0] = raan₀[k]
        consts[k, _SGP4_C_ARGP0] = argp₀[k]
        consts[k, _SGP4_C_M0] = M₀[k]
        consts[k, _SGP4_C_BSTAR] = bstar[k]
        consts[k, _SGP4_C_A] = all₀
        consts[k, _SGP4_C_N] = nll₀
        consts[k, _SGP4_C_QOMS2T] = QOMS2T
        consts[k, _SGP4_C_BETA0] = β₀
        consts[k, _SGP4_C_XI] = ξ
        consts[k, _SGP4_C_ETA] = η
        consts[k, _SGP4_C_SINI0] = sin_i0
        consts[k, _SGP4_C_THETA] = θ
        consts[k, _SGP4_C_THETA2] = θ²
        consts[k, _SGP4_C_C1] = C1
        consts[k, _SGP4_C_C3] = C3
        consts[k, _SGP4_C_C4] = C4
        consts[k, _SGP4_C_C5] = C5
        consts[k, _SGP4_C_D2] = D2
        consts[k, _SGP4_C_D3] = D3
        consts[k, _SGP4_C_D4] = D4
        consts[k, _SGP4_C_DM] = ∂M
        consts[k, _SGP4_C_DARGP] = ∂ω
        consts[k, _SGP4_C_DRAAN] = ∂Ω
    end

    return Sgp4DeviceElements(consts, algo, R0, XKE, k₂, A₃₀)
end

# GPU 安全的 rem2pi(x, RoundToZero)：同号、|·|<2π，数值上等价（大角度约减差异极小）。
@inline _rem2pi_zero(x::T) where {T<:AbstractFloat} = x - T(2π) * trunc(x / T(2π))

# 近地 SGP4 传播核：逐 (卫星, 时刻) 由常数 + Δt(min) 算 TEME 位置/速度。
@kernel function _sgp4_kernel!(
    positions, velocities, consts, algo, tspan, R0, XKE, k₂, A₃₀, n_times,
)
    linear_index = @index(Global)
    linear_index -= 1
    time_index = linear_index % n_times + 1
    sat_index = linear_index ÷ n_times + 1
    T = eltype(positions)

    e₀ = consts[sat_index, _SGP4_C_E0]
    i₀ = consts[sat_index, _SGP4_C_I0]
    Ω₀ = consts[sat_index, _SGP4_C_RAAN0]
    ω₀ = consts[sat_index, _SGP4_C_ARGP0]
    M₀ = consts[sat_index, _SGP4_C_M0]
    bstar = consts[sat_index, _SGP4_C_BSTAR]
    all₀ = consts[sat_index, _SGP4_C_A]
    nll₀ = consts[sat_index, _SGP4_C_N]
    QOMS2T = consts[sat_index, _SGP4_C_QOMS2T]
    β₀ = consts[sat_index, _SGP4_C_BETA0]
    ξ = consts[sat_index, _SGP4_C_XI]
    η = consts[sat_index, _SGP4_C_ETA]
    sin_i₀ = consts[sat_index, _SGP4_C_SINI0]
    θ = consts[sat_index, _SGP4_C_THETA]
    θ² = consts[sat_index, _SGP4_C_THETA2]
    C1 = consts[sat_index, _SGP4_C_C1]
    C3 = consts[sat_index, _SGP4_C_C3]
    C4 = consts[sat_index, _SGP4_C_C4]
    C5 = consts[sat_index, _SGP4_C_C5]
    D2 = consts[sat_index, _SGP4_C_D2]
    D3 = consts[sat_index, _SGP4_C_D3]
    D4 = consts[sat_index, _SGP4_C_D4]
    ∂M = consts[sat_index, _SGP4_C_DM]
    ∂ω = consts[sat_index, _SGP4_C_DARGP]
    ∂Ω = consts[sat_index, _SGP4_C_DRAAN]
    is_sgp4 = algo[sat_index] == _SGP4_ALGO_SGP4

    Δt = T(tspan[time_index])
    sin_i_k = sin_i₀

    # 长期项（大气阻力 + 引力）。
    M_k = M₀ + ∂M * Δt
    Ω_k = Ω₀ + ∂Ω * Δt - (T(21) / 2) * (nll₀ * k₂ * θ) / (all₀^2 * β₀^2) * C1 * Δt^2
    ω_k = ω₀ + ∂ω * Δt

    if is_sgp4
        sin_M₀, cos_M₀ = sincos(M₀)
        δω = bstar * C3 * cos(ω₀) * Δt
        δM = e₀ > T(1e-4) ?
             -(T(2) / 3) * QOMS2T * bstar * ξ^4 * one(T) / (e₀ * η) *
             ((one(T) + η * cos(M_k))^3 - (one(T) + η * cos_M₀)^3) :
             zero(T)
        M_k += δω + δM
        ω_k += -δω - δM
        e_k = e₀ - bstar * C4 * Δt - bstar * C5 * (sin(M_k) - sin_M₀)
        poly_a = one(T) + Δt * (-C1 + Δt * (-D2 + Δt * (-D3 + Δt * (-D4))))
        a_k = all₀ * poly_a * poly_a
        cIL2 = (T(3) / 2) * C1
        cIL3 = D2 + 2C1^2
        cIL4 = (3D3 + 12C1 * D2 + 10C1^3) / 4
        cIL5 = (3D4 + 12C1 * D3 + 6D2^2 + 30C1^2 * D2 + 15C1^4) / 5
        IL = M_k + ω_k + Ω_k +
             nll₀ * Δt^2 * (cIL2 + Δt * (cIL3 + Δt * (cIL4 + Δt * cIL5)))
    else
        e_k = e₀ - bstar * C4 * Δt
        poly_a = one(T) - C1 * Δt
        a_k = all₀ * poly_a * poly_a
        IL = M_k + ω_k + Ω_k + (T(3) / 2) * nll₀ * C1 * Δt^2
    end

    M_k_aux = M_k + ω_k + Ω_k
    Ω_k = _rem2pi_zero(Ω_k)
    ω_k = _rem2pi_zero(ω_k)
    M_k_aux = _rem2pi_zero(M_k_aux)

    e_k = max(e_k, T(1e-6))
    n_k = XKE / sqrt(a_k^3)

    # 长周期项。
    sin_ω_k, cos_ω_k = sincos(ω_k)
    a_xN = e_k * cos_ω_k
    a_yNL = A₃₀ * sin_i_k / (4k₂ * a_k * (one(T) - e_k^2))
    a_yN = e_k * sin_ω_k + a_yNL
    IL_L = (one(T) / 2) * a_yNL * a_xN * (3 + 5θ) / (one(T) + θ)
    IL_T = IL + IL_L

    # Kepler 方程解 (E + ω)。
    U = mod(IL_T - Ω_k, T(2π))
    E_ω = U
    sin_E_ω = zero(T)
    cos_E_ω = zero(T)
    for _ in 1:10
        sin_E_ω, cos_E_ω = sincos(E_ω)
        ΔE_ω = (U - a_yN * cos_E_ω + a_xN * sin_E_ω - E_ω) /
               (one(T) - a_yN * sin_E_ω - a_xN * cos_E_ω)
        abs(ΔE_ω) >= T(0.95) && (ΔE_ω = sign(ΔE_ω) * T(0.95))
        E_ω += ΔE_ω
        abs(ΔE_ω) < T(1e-12) && break
    end

    # 短周期项。
    e_cos_E = a_xN * cos_E_ω + a_yN * sin_E_ω
    e_sin_E = a_xN * sin_E_ω - a_yN * cos_E_ω
    e_L² = a_xN^2 + a_yN^2
    p_L = a_k * (one(T) - e_L²)
    p_L² = p_L^2
    r = a_k * (one(T) - e_cos_E)
    ṙ = XKE * sqrt(a_k) * e_sin_E / r
    rḟ = XKE * sqrt(p_L) / r
    auxsp = e_sin_E / (one(T) + sqrt(one(T) - e_L²))
    cos_u = a_k / r * (cos_E_ω - a_xN + a_yN * auxsp)
    sin_u = a_k / r * (sin_E_ω - a_yN - a_xN * auxsp)
    cos_2u = one(T) - 2sin_u^2
    sin_2u = 2cos_u * sin_u
    u = atan(sin_u, cos_u)

    Δr = k₂ / (2p_L) * (one(T) - θ²) * cos_2u
    Δu = -k₂ / (4p_L²) * (7θ² - one(T)) * sin_2u
    ΔΩ = 3k₂ * θ / (2p_L²) * sin_2u
    Δi = 3k₂ * θ / (2p_L²) * sin_i_k * cos_2u
    Δṙ = -k₂ * n_k / p_L * (one(T) - θ²) * sin_2u
    Δrḟ = k₂ * n_k / p_L * ((one(T) - θ²) * cos_2u - (T(3) / 2) * (one(T) - 3θ²))

    r_k = r * (one(T) - (T(3) / 2) * k₂ * sqrt(one(T) - e_L²) / p_L² * (3θ² - one(T))) + Δr
    u_k = u + Δu
    Ω_k = Ω_k + ΔΩ
    i_k = i₀ + Δi
    ṙ_k = ṙ + Δṙ
    rḟ_k = rḟ + Δrḟ

    sin_Ω_k, cos_Ω_k = sincos(Ω_k)
    sin_i_k, cos_i_k = sincos(i_k)
    sin_u_k, cos_u_k = sincos(u_k)

    Mx = -sin_Ω_k * cos_i_k
    My = +cos_Ω_k * cos_i_k
    Mz = sin_i_k
    Nx = +cos_Ω_k
    Ny = +sin_Ω_k
    Nz = zero(T)

    Ux = Mx * sin_u_k + Nx * cos_u_k
    Uy = My * sin_u_k + Ny * cos_u_k
    Uz = Mz * sin_u_k + Nz * cos_u_k
    Vx = Mx * cos_u_k - Nx * sin_u_k
    Vy = My * cos_u_k - Ny * sin_u_k
    Vz = Mz * cos_u_k - Nz * sin_u_k

    positions[sat_index, time_index, 1] = r_k * Ux * R0
    positions[sat_index, time_index, 2] = r_k * Uy * R0
    positions[sat_index, time_index, 3] = r_k * Uz * R0
    velocities[sat_index, time_index, 1] = (ṙ_k * Ux + rḟ_k * Vx) * R0 / 60
    velocities[sat_index, time_index, 2] = (ṙ_k * Uy + rḟ_k * Vy) * R0 / 60
    velocities[sat_index, time_index, 3] = (ṙ_k * Uz + rḟ_k * Vz) * R0 / 60
end

"""
    sgp4_propagate_gpu(elements::Sgp4DeviceElements, tspan_min; velocities=false)
        -> positions | (positions, velocities)

在 KernelAbstractions 后端上对 `elements`（`sgp4_init_host` 产出，可先 `to_device`）批量做
**近地 SGP4** 传播，返回 TEME `(N, T, 3)` 位置（km）。`tspan_min` 长度 T（分钟，自历元起）。
`velocities=true` 时额外返回 `(N, T, 3)` 速度（km/s）。输入设备常数即得设备数组（不回 host），
可经 `device_pipeline` 直接把 TEME 位置/速度喂给 `evaluate_isl_batch_gpu`。

    sgp4_propagate_gpu(n₀, e₀, i₀, raan₀, argp₀, M₀, bstar, tspan_min; sgp4c, velocities)

便捷重载：先 `sgp4_init_host` 再传播（host 驻留；`n₀` rad/min，角度 rad）。
"""
function sgp4_propagate_gpu(
    elements::Sgp4DeviceElements{T},
    tspan_min::AbstractVector;
    velocities::Bool=false,
) where {T<:AbstractFloat}
    n_sat = size(elements.consts, 1)
    n_times = length(tspan_min)
    n_times > 0 || throw(ArgumentError("tspan_min must be non-empty"))
    backend = get_backend(elements.consts)
    device_tspan = adapt(backend, T.(tspan_min))
    positions = similar(elements.consts, T, (n_sat, n_times, 3))
    vel = similar(elements.consts, T, (n_sat, n_times, 3))
    _wait_event(_sgp4_kernel!(backend)(
        positions, vel, elements.consts, elements.algo, device_tspan,
        elements.R0, elements.XKE, elements.k2, elements.A30, n_times;
        ndrange=n_sat * n_times,
    ))
    return velocities ? (positions, vel) : positions
end

function sgp4_propagate_gpu(
    n₀::AbstractVector{T},
    e₀::AbstractVector{T},
    i₀::AbstractVector{T},
    raan₀::AbstractVector{T},
    argp₀::AbstractVector{T},
    M₀::AbstractVector{T},
    bstar::AbstractVector{T},
    tspan_min::AbstractVector;
    sgp4c::NamedTuple=_SGP4_WGS84,
    velocities::Bool=false,
) where {T<:AbstractFloat}
    elements = sgp4_init_host(n₀, e₀, i₀, raan₀, argp₀, M₀, bstar; sgp4c=sgp4c)
    return sgp4_propagate_gpu(elements, tspan_min; velocities=velocities)
end

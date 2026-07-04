"""
    differentiable_propagator.jl

将 SGP4 传播与自动微分对接，实现双向可微传播：
  - 前向模式：ForwardDiff（验证通过，测试通过）
  - 反向模式：Zygote（新增）

核心设计：
  1. 预初始化 sgpd4 在可微区域外（TLE解析不可微）
  2. 只对 sgp4!(sgp4d, t) 做 AD（纯数值计算，无字符串）
  3. 提供统一接口：propagate_with_gradient

用法：
  grad = propagate_with_gradient(tle, t, loss_fn)
  # 返回 ∂loss/∂TLE_params，同时支持 ForwardDiff 和 Zygote
"""

import ForwardDiff
import Zygote
import SatelliteToolboxSgp4
import SatelliteToolbox
using StaticArrays: SVector

export propagate_with_gradient, constellation_gradient, smooth_step, smooth_abs

# ── 单位转换 ──
const D2R = π / 180
const REV_DAY_TO_RAD_MIN = 2π / (24 * 60)

# ── 光滑近似（保留，SGP4 内部分支已足够光滑但备用） ──
"""
    smooth_step(x; k=20.0)

光滑阶跃近似: σ(kx) = 1/(1+exp(-kx))
AD 安全，梯度处处连续。
"""
smooth_step(x; k::Real=20.0) = one(x) / (one(x) + exp(-k * x))

"""
    smooth_abs(x; k=20.0)

光滑绝对值近似: √(x² + 1/k)
AD 安全，在 x=0 处可微。
"""
smooth_abs(x; k::Real=20.0) = sqrt(x^2 + one(x) / k)

# ── SGP4 传播核（AD 透明） ──

"""
    _sgp4_forward(tle, t_min::Number) -> SVector{3}

从 TLE 初始化 SGP4 并传播到 t_min（分钟），返回 TEME 位置向量 [x, y, z] km。
整个函数对 ForwardDiff 和 Zygote 都透明。

注意：sgp4_init 内部的字符串解析只在构造 TLE 时执行一次；
t_min 带 Dual 数时，sgp4! 内部会做 Dual 数传播。
"""
function _sgp4_forward(tle::SatelliteToolbox.TLE, t_min::T) where T <: Number
    # 用 T 类型初始化（使 sgp4d 内部用 Dual 数）
    epoch = SatelliteToolboxSgp4.tle_epoch(tle)
    sgp4d = SatelliteToolboxSgp4.sgp4_init(
        epoch,
        T(tle.mean_motion         * REV_DAY_TO_RAD_MIN),
        T(tle.eccentricity),
        T(tle.inclination          * D2R),
        T(tle.raan                 * D2R),
        T(tle.argument_of_perigee  * D2R),
        T(tle.mean_anomaly         * D2R),
        T(tle.bstar),
    )
    r, _ = SatelliteToolboxSgp4.sgp4!(sgp4d, t_min)
    return r  # [x, y, z] TEME
end

"""
    _tle_to_params(tle) -> Vector{Float64}

将 TLE 转为参数向量 [n₀, e₀, i₀, Ω₀, ω₀, M₀, bstar]（SGP4 内部单位）。
"""
function _tle_to_params(tle::SatelliteToolbox.TLE)::Vector{Float64}
    return [
        tle.mean_motion         * REV_DAY_TO_RAD_MIN,  # n₀  rad/min
        tle.eccentricity,                                # e₀
        tle.inclination          * D2R,                  # i₀  rad
        tle.raan                 * D2R,                  # Ω₀  rad
        tle.argument_of_perigee  * D2R,                  # ω₀  rad
        tle.mean_anomaly         * D2R,                  # M₀  rad
        tle.bstar,                                       # bstar
    ]
end

"""
    _sgp4_from_params(params, tle_epoch, t_min) -> SVector{3}

从参数向量初始化 SGP4 并传播（纯数值，无字符串解析）。
可用于 ForwardDiff 和 Zygote 的 AD 区域。
"""
function _sgp4_from_params(params::AbstractVector{T}, tle_epoch, t_min::T) where T <: Number
    sgp4d = SatelliteToolboxSgp4.sgp4_init(
        tle_epoch,
        T(params[1]),   # n₀
        T(params[2]),   # e₀
        T(params[3]),   # i₀
        T(params[4]),   # Ω₀
        T(params[5]),   # ω₀
        T(params[6]),   # M₀
        T(params[7]),   # bstar
    )
    r, _ = SatelliteToolboxSgp4.sgp4!(sgp4d, t_min)
    return r
end

# ── 前向模式：ForwardDiff ──

"""
    propagate_forward(tle, t_min; loss_fn=nothing) -> Union{Matrix, Vector}

使用 ForwardDiff 计算 ∂r/∂params 雅可比矩阵。

若提供 loss_fn，返回 ∂loss/∂params 梯度。
t_min 的单位为**分钟**（SGP4 内部单位）。
"""
function propagate_forward(tle::SatelliteToolbox.TLE, t_min::Float64)
    params = _tle_to_params(tle)
    epoch  = SatelliteToolboxSgp4.tle_epoch(tle)

    J = ForwardDiff.jacobian(params) do p
        T = eltype(p)
        _sgp4_from_params(p, epoch, T(t_min))
    end
    return J  # 3×7 雅可比
end

function propagate_forward(tle::SatelliteToolbox.TLE, t_min::Float64, loss_fn::Function)
    params = _tle_to_params(tle)
    epoch  = SatelliteToolboxSgp4.tle_epoch(tle)

    grad = ForwardDiff.gradient(params) do p
        T = eltype(p)
        r = _sgp4_from_params(p, epoch, T(t_min))
        loss_fn(r)
    end
    return grad  # 7-向量
end

# ── 反向模式：Zygote ──

"""
    propagate_reverse(tle, t_min; loss_fn=nothing) -> Vector

使用 Zygote 反向模式计算 ∂loss/∂params。
对大星座批量传播更高效（输出维度 << 输入维度）。
"""
function propagate_reverse(tle::SatelliteToolbox.TLE, t_min::Float64, loss_fn::Function)
    params = _tle_to_params(tle)
    epoch  = SatelliteToolboxSgp4.tle_epoch(tle)

    # Zygote 需要纯函数（无 mutation）
    # 注意：Zygote 的梯度要求 y = f(x) 中 x 和 y 都是标量/向量，
    # 且 f 内部不修改全局状态。sgp4_init + sgp4! 是纯函数，没问题。
    function loss_fn_params(p)
        T = eltype(p)
        r = _sgp4_from_params(p, epoch, T(t_min))
        return loss_fn(r)
    end
    grad = Zygote.gradient(loss_fn_params, params)[1]
    return grad  # 7-向量
end

function propagate_reverse(tle::SatelliteToolbox.TLE, t_min::Float64)
    # 无 loss_fn 时，返回 ∂r/∂params 的转置（反向模式做 3 次推演）
    params = _tle_to_params(tle)
    epoch  = SatelliteToolboxSgp4.tle_epoch(tle)

    function pos_i(p, i)
        T = eltype(p)
        r = _sgp4_from_params(p, epoch, T(t_min))
        return r[i]
    end

    J = hcat([Zygote.gradient(p -> pos_i(p, i), params)[1] for i in 1:3]...)
    return J  # 7×3
end

# ── 整星座可微传播（Zygote 反向模式） ──

"""
    _constellation_to_params(tles) -> (Vector{Float64}, Vector{DateTime})

将星座中所有卫星的 TLE 参数提取为一个大平向量。
返回 (all_params, epochs)，all_params 长度为 7×n_sats。
"""
function _constellation_to_params(tles::Vector{SatelliteToolbox.TLE})
    epochs = [SatelliteToolboxSgp4.tle_epoch(tle) for tle in tles]
    params = Float64[]
    for tle in tles
        append!(params, _tle_to_params(tle))
    end
    return params, epochs
end

"""
    _propagate_constellation_from_params(all_params, epochs, t_min) -> Vector{Float64}

从平铺参数向量传播整个星座。
返回平铺的位置向量 [x1,y1,z1, x2,y2,z2, ...]（长度 3×n_sats）。
"""
function _propagate_constellation_from_params(
    all_params::AbstractVector{T},
    epochs::Vector,
    t_min::T,
) where T <: Number
    n_sats = length(epochs)
    # 使用 reduce 而非 push!（Zygote 不支持 mutation）
    return reduce(vcat, [let i=i
        idx = (i-1) * 7 + 1
        r = _sgp4_from_params(all_params[idx:idx+6], epochs[i], t_min)
        [r[1], r[2], r[3]]
    end for i in 1:n_sats])
end

"""
    constellation_gradient(tles, t_min, loss_fn; mode=:reverse)

计算整个星座的梯度。

`loss_fn` 接收一个平铺位置向量 [x1,y1,z1, x2,y2,z2, ...]（3×n_sats 长度），
返回标量损失。返回梯度 ∂loss/∂(所有 TLE 参数)（长度 7×n_sats）。

示例：
```
tles = [read_tle(l1, l2) for (l1, l2) in satellite_tle_pairs]
# 最小化所有卫星到原点的距离平方和
loss_fn(positions) = sum(abs2, positions)
grad = constellation_gradient(tles, 60.0, loss_fn, mode=:reverse)
```
"""
function constellation_gradient(
    tles::Vector{SatelliteToolbox.TLE},
    t_min::Float64,
    loss_fn::Function;
    mode::Symbol = :reverse,
)
    all_params, epochs = _constellation_to_params(tles)

    if mode == :reverse
        function fwd(p)
            T = eltype(p)
            pos = _propagate_constellation_from_params(p, epochs, T(t_min))
            return loss_fn(pos)
        end
        grad = Zygote.gradient(fwd, all_params)[1]
        return grad
    elseif mode == :forward
        grad = ForwardDiff.gradient(all_params) do p
            T = eltype(p)
            pos = _propagate_constellation_from_params(p, epochs, T(t_min))
            return loss_fn(pos)
        end
        return grad
    else
        error("Unknown mode: $mode")
    end
end

# ── 统一接口 ──

"""
    propagate_with_gradient(tle, t_min; mode=:forward, loss_fn=nothing)

统一可微传播接口。

参数
- `tle`: SatelliteToolbox.TLE 对象
- `t_min`: 传播时间（分钟）
- `mode`: `:forward`（ForwardDiff）或 `:reverse`（Zygote）
- `loss_fn`: 若提供，返回 ∂loss/∂params；否则返回雅可比 ∂r/∂params

示例
```
tle = read_tle(line1, line2)
J = propagate_with_gradient(tle, 60.0, mode=:forward)
grad = propagate_with_gradient(tle, 60.0, mode=:reverse, loss_fn=r->sum(r.^2))
```
"""
function propagate_with_gradient(
    tle::SatelliteToolbox.TLE,
    t_min::Float64;
    mode::Symbol = :forward,
    loss_fn::Union{Function,Nothing} = nothing,
)
    if mode == :forward
        return loss_fn === nothing ?
               propagate_forward(tle, t_min) :
               propagate_forward(tle, t_min, loss_fn)
    elseif mode == :reverse
        return loss_fn === nothing ?
               propagate_reverse(tle, t_min) :
               propagate_reverse(tle, t_min, loss_fn)
    else
        error("Unknown mode: $mode (use :forward or :reverse)")
    end
end

# ISL 批量评估（KernelAbstractions，SoA 输出）
#
# 对齐 SatelliteSimLink 的 `evaluate_isl` 语义：
#   1. 距离 + LOS（地球遮挡）+ 距离约束   → available / distance / delay / line_of_sight
#   2. 若提供速度：RTN 相对仰角 / 方位角(激光终端) / 直线外推持续时长 → 细化 available
#
# 输出为 `(n_pairs, n_times)` 的裸数组（Struct-of-Arrays），替代 CPU 版返回的
# `Vector{NamedTuple}`（Array-of-Structs），使链路层能常驻设备、并被批量/可微处理。
#
# 说明：本文件被 `SatelliteSimGPU.jl` include 进模块，`_SPEED_OF_LIGHT_KM_S`、
# `_wait_event` 等在模块作用域内可见。

export evaluate_isl_batch_gpu

const _WGS84_EQUATORIAL_RADIUS_KM = 6378.137

# ── 设备内联几何 ─────────────────────────────────────────────────────────────

@inline function _isl_has_los_gpu(
    ax::T, ay::T, az::T, bx::T, by::T, bz::T, earth_radius::T,
) where {T<:AbstractFloat}
    sx, sy, sz = bx - ax, by - ay, bz - az
    s2 = sx * sx + sy * sy + sz * sz
    if s2 <= zero(T)
        return sqrt(ax * ax + ay * ay + az * az) >= earth_radius
    end
    t = -(ax * sx + ay * sy + az * sz) / s2
    t = t < zero(T) ? zero(T) : (t > one(T) ? one(T) : t)
    cx, cy, cz = ax + t * sx, ay + t * sy, az + t * sz
    return sqrt(cx * cx + cy * cy + cz * cz) >= earth_radius
end

# RTN 相对坐标：R=指向地心(a/|a|), T=速度方向(v/|v|), N=R×T。返回 target(b) 在 RTN 下的 (r,t,n)。
@inline function _isl_rtn_gpu(
    ax::T, ay::T, az::T, vx::T, vy::T, vz::T, bx::T, by::T, bz::T,
) where {T<:AbstractFloat}
    ra = sqrt(ax * ax + ay * ay + az * az)
    rx, ry, rz = ax / ra, ay / ra, az / ra
    rv = sqrt(vx * vx + vy * vy + vz * vz)
    tx, ty, tz = vx / rv, vy / rv, vz / rv
    nx = ry * tz - rz * ty
    ny = rz * tx - rx * tz
    nz = rx * ty - ry * tx
    rn = sqrt(nx * nx + ny * ny + nz * nz)
    nx, ny, nz = nx / rn, ny / rn, nz / rn
    relx, rely, relz = bx - ax, by - ay, bz - az
    r = relx * rx + rely * ry + relz * rz
    t = relx * tx + rely * ty + relz * tz
    n = relx * nx + rely * ny + relz * nz
    return r, t, n
end

@inline function _isl_elev_from_rtn_gpu(r::T, t::T, n::T) where {T<:AbstractFloat}
    dist = sqrt(r * r + t * t + n * n)
    dist < T(1e-10) && return T(90.0)
    return asin(abs(r) / dist) * T(180.0 / π)
end

@inline function _isl_azim_from_rtn_gpu(t::T, n::T) where {T<:AbstractFloat}
    denom = sqrt(n * n + t * t)
    denom < T(1e-10) && return one(T)
    return n / denom
end

@inline function _isl_azimuth_ok_gpu(
    cos_psi::T, terminal_id::Int, cone_angle_deg::T,
) where {T<:AbstractFloat}
    cos_rho = cos(cone_angle_deg * T(π / 180.0))
    if terminal_id == 4
        return cos_psi >= cos_rho
    elseif terminal_id == 3
        return cos_psi <= -cos_rho
    elseif terminal_id == 1
        return cos_psi > zero(T)
    elseif terminal_id == 2
        return cos_psi < zero(T)
    else
        return true
    end
end

# 直线外推持续时长：每 1s 检查 |rel_pos + t·rel_vel|，超出 max_range 即断链。
@inline function _isl_duration_gpu(
    ax::T, ay::T, az::T, vax::T, vay::T, vaz::T,
    bx::T, by::T, bz::T, vbx::T, vby::T, vbz::T,
    max_range::T, time_horizon::T,
) where {T<:AbstractFloat}
    rpx, rpy, rpz = bx - ax, by - ay, bz - az
    rvx, rvy, rvz = vbx - vax, vby - vay, vbz - vaz
    tt = one(T)
    while tt <= time_horizon
        px = rpx + tt * rvx
        py = rpy + tt * rvy
        pz = rpz + tt * rvz
        if sqrt(px * px + py * py + pz * pz) > max_range
            return tt
        end
        tt += one(T)
    end
    return time_horizon
end

# ── 核 ───────────────────────────────────────────────────────────────────────

@kernel function _isl_kernel!(
    available, distances, delays, line_of_sight, elevations, cos_psis, durations,
    positions, velocities, pair_src, pair_dst,
    has_vel, max_range, require_los, earth_radius,
    cone_angle_deg, min_duration, time_horizon, terminal_id,
    speed_of_light, milliseconds, n_times,
)
    linear_index = @index(Global)
    linear_index -= 1
    time_index = linear_index % n_times + 1
    pair_index = linear_index ÷ n_times + 1

    i = pair_src[pair_index]
    j = pair_dst[pair_index]

    ax = positions[i, time_index, 1]
    ay = positions[i, time_index, 2]
    az = positions[i, time_index, 3]
    bx = positions[j, time_index, 1]
    by = positions[j, time_index, 2]
    bz = positions[j, time_index, 3]

    dx, dy, dz = ax - bx, ay - by, az - bz
    d = sqrt(dx * dx + dy * dy + dz * dz)

    los = _isl_has_los_gpu(ax, ay, az, bx, by, bz, earth_radius)
    los_ok = (!require_los) | los
    avail = (d <= max_range) & los_ok

    elevation = oftype(d, 90.0)
    cos_psi = oftype(d, 1.0)
    duration = oftype(d, 0.0)

    if has_vel && avail
        vax = velocities[i, time_index, 1]
        vay = velocities[i, time_index, 2]
        vaz = velocities[i, time_index, 3]
        vbx = velocities[j, time_index, 1]
        vby = velocities[j, time_index, 2]
        vbz = velocities[j, time_index, 3]

        r, t, n = _isl_rtn_gpu(ax, ay, az, vax, vay, vaz, bx, by, bz)
        elevation = _isl_elev_from_rtn_gpu(r, t, n)
        avail = avail & (elevation <= cone_angle_deg)
        if avail
            cos_psi = _isl_azim_from_rtn_gpu(t, n)
            avail = avail & _isl_azimuth_ok_gpu(cos_psi, terminal_id, cone_angle_deg)
            if avail
                duration = _isl_duration_gpu(
                    ax, ay, az, vax, vay, vaz,
                    bx, by, bz, vbx, vby, vbz,
                    max_range, time_horizon,
                )
                avail = avail & (duration >= min_duration)
            end
        end
    end

    available[pair_index, time_index] = avail
    distances[pair_index, time_index] = d
    delays[pair_index, time_index] = d / speed_of_light * milliseconds
    line_of_sight[pair_index, time_index] = los
    elevations[pair_index, time_index] = elevation
    cos_psis[pair_index, time_index] = cos_psi
    durations[pair_index, time_index] = duration
end

# ── 主机入口 ─────────────────────────────────────────────────────────────────

"""
    evaluate_isl_batch_gpu(positions, isl_pairs; velocities=nothing, kwargs...)
        -> NamedTuple of `(n_pairs, n_times)` arrays

在 KernelAbstractions 后端上批量评估所有 `(链路对 × 时刻)` 的 ISL 物理状态，
对齐 `SatelliteSimLink.evaluate_isl`。`positions`/`velocities` 形状 `(N, NT, 3)`，
ECEF km / (km/s)；`isl_pairs` 是 `Vector{Tuple{Int,Int}}`（1-based 卫星编号）。

返回 NamedTuple：`available::Bool`、`distance_km`、`delay_ms`、`line_of_sight::Bool`、
`elevation_deg`、`cos_psi`、`duration_s`，均为 `(n_pairs, n_times)`。
不提供 `velocities` 时只做距离 + LOS + 距离约束（elevation=90, cos_psi=1, duration=0）。
"""
function evaluate_isl_batch_gpu(
    positions::AbstractArray{T,3},
    isl_pairs::AbstractVector{<:Tuple{Integer,Integer}};
    velocities::Union{Nothing,AbstractArray{T,3}}=nothing,
    isl_max_range_km::Real=5000.0,
    isl_require_los::Bool=true,
    isl_max_cone_angle_deg::Real=60.0,
    isl_min_duration_s::Real=10.0,
    time_horizon_s::Real=300.0,
    terminal_id::Integer=4,
    earth_radius_km::Real=_WGS84_EQUATORIAL_RADIUS_KM,
) where {T<:AbstractFloat}
    size(positions, 3) == 3 ||
        throw(ArgumentError("positions must have shape (N, NT, 3)"))
    n_satellites, n_times, _ = size(positions)
    n_satellites > 0 && n_times > 0 ||
        throw(ArgumentError("positions must be non-empty"))
    if velocities !== nothing
        size(velocities) == size(positions) ||
            throw(ArgumentError("velocities must match positions shape (N, NT, 3)"))
    end
    n_pairs = length(isl_pairs)
    for (i, j) in isl_pairs
        (1 <= i <= n_satellites && 1 <= j <= n_satellites) ||
            throw(ArgumentError("isl_pairs indices must be within 1:$(n_satellites)"))
    end

    backend = get_backend(positions)
    src_host = Int[first(p) for p in isl_pairs]
    dst_host = Int[last(p) for p in isl_pairs]
    pair_src = adapt(backend, src_host)
    pair_dst = adapt(backend, dst_host)

    available = similar(positions, Bool, (n_pairs, n_times))
    distances = similar(positions, T, (n_pairs, n_times))
    delays = similar(positions, T, (n_pairs, n_times))
    line_of_sight = similar(positions, Bool, (n_pairs, n_times))
    elevations = similar(positions, T, (n_pairs, n_times))
    cos_psis = similar(positions, T, (n_pairs, n_times))
    durations = similar(positions, T, (n_pairs, n_times))

    has_vel = velocities !== nothing
    vel_arg = has_vel ? velocities : positions   # 占位；has_vel=false 时不读取

    if n_pairs > 0
        _wait_event(_isl_kernel!(backend)(
            available, distances, delays, line_of_sight,
            elevations, cos_psis, durations,
            positions, vel_arg, pair_src, pair_dst,
            has_vel, T(isl_max_range_km), isl_require_los, T(earth_radius_km),
            T(isl_max_cone_angle_deg), T(isl_min_duration_s), T(time_horizon_s),
            Int(terminal_id), T(_SPEED_OF_LIGHT_KM_S), T(1000.0), n_times;
            ndrange=n_pairs * n_times,
        ))
    end

    return (
        available=available,
        distance_km=distances,
        delay_ms=delays,
        line_of_sight=line_of_sight,
        elevation_deg=elevations,
        cos_psi=cos_psis,
        duration_s=durations,
    )
end

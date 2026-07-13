# Golden 参考：ISL 批量评估（标量实现，冻结自 SatelliteSimLink 的 evaluate_isl 语义）。
# 用作 evaluate_isl_batch_gpu 的对标基准。若上游 evaluate_isl 语义变更，需同步本文件。

module GoldenISLReference

using LinearAlgebra: norm, cross, dot

const EARTH_RADIUS_KM = 6378.137
const SPEED_OF_LIGHT_KM_S = 299_792.458

_distance(a, b) = norm(collect(Float64, a) .- collect(Float64, b))

function _has_los(a, b; earth_radius=EARTH_RADIUS_KM)
    av = collect(Float64, a)
    bv = collect(Float64, b)
    s = bv .- av
    s2 = s[1]^2 + s[2]^2 + s[3]^2
    s2 ≈ 0 && return norm(av) >= earth_radius
    t = clamp(-(av[1] * s[1] + av[2] * s[2] + av[3] * s[3]) / s2, 0.0, 1.0)
    closest = av .+ t .* s
    return norm(closest) >= earth_radius
end

function _rtn(pos, vel, target)
    p = collect(Float64, pos)
    v = collect(Float64, vel)
    tgt = collect(Float64, target)
    all(isfinite, p) && all(isfinite, v) && all(isfinite, tgt) ||
        return false, 0.0, 0.0, 0.0
    radius = norm(p)
    radius > 0.0 || return false, 0.0, 0.0, 0.0
    R = p ./ radius
    velocity_scale = maximum(abs, v)
    velocity_scale > 0.0 || return false, 0.0, 0.0, 0.0
    scaled_velocity = v ./ velocity_scale
    normal = cross(R, scaled_velocity)
    normal_norm = norm(normal)
    normal_norm > 16 * eps(Float64) * norm(scaled_velocity) ||
        return false, 0.0, 0.0, 0.0
    N = normal ./ normal_norm
    T = cross(N, R)
    rel = tgt .- p
    return true, dot(rel, R), dot(rel, T), dot(rel, N)
end

function _elev_from_rtn(r, t, n)
    horizontal = hypot(t, n)
    dist = hypot(r, horizontal)
    dist < 1e-10 && return 90.0
    return rad2deg(atan(abs(r), horizontal))
end

function _azim_from_rtn(t, n)
    denom = hypot(n, t)
    denom < 1e-10 && return 1.0
    return clamp(n / denom, -1.0, 1.0)
end

function _azimuth_ok(cos_psi, terminal_id, cone_deg)
    cos_rho = cos(deg2rad(cone_deg))
    terminal_id == 4 && return cos_psi >= cos_rho
    terminal_id == 3 && return cos_psi <= -cos_rho
    terminal_id == 1 && return cos_psi > 0
    terminal_id == 2 && return cos_psi < 0
    return true
end

function _duration(a, va, b, vb; max_range=5000.0, time_horizon=300.0)
    rel_pos = collect(Float64, b) .- collect(Float64, a)
    rel_vel = collect(Float64, vb) .- collect(Float64, va)
    range = Float64(max_range)
    horizon = Float64(time_horizon)
    position_scale = max(range, maximum(abs, rel_pos))
    scaled_position = rel_pos ./ position_scale
    scaled_range = range / position_scale
    scaled_distance = norm(scaled_position)
    range_residual =
        (scaled_distance - scaled_range) * (scaled_distance + scaled_range)
    range_residual > 0.0 && return 0.0

    velocity_scale = maximum(abs, rel_vel)
    velocity_scale == 0.0 && return horizon
    scaled_velocity = rel_vel ./ velocity_scale
    speed_squared = dot(scaled_velocity, scaled_velocity)
    radial_rate = dot(scaled_position, scaled_velocity)
    range_residual == 0.0 && radial_rate >= 0.0 && return 0.0

    discriminant = max(radial_rate^2 - speed_squared * range_residual, 0.0)
    root = sqrt(discriminant)
    crossing = if radial_rate >= 0.0
        -range_residual / (radial_rate + root)
    else
        (-radial_rate + root) / speed_squared
    end
    time_scale = position_scale / velocity_scale
    crossing = if isfinite(time_scale)
        crossing * time_scale
    else
        (crossing * position_scale) / velocity_scale
    end
    return clamp(crossing, 0.0, horizon)
end

"""评估单条 ISL，返回 (available, distance, delay_ms, los, elevation_deg, cos_psi, duration_s)。"""
function evaluate_isl_one(
    a, b;
    va=nothing, vb=nothing,
    max_range=5000.0, require_los=true, cone_deg=60.0,
    min_duration=10.0, time_horizon=300.0, terminal_id=4,
)
    d = _distance(a, b)
    los = _has_los(a, b)
    avail = (d <= max_range) && (!require_los || los)

    elevation = 90.0
    cos_psi = 1.0
    duration = 0.0

    if avail && va !== nothing
        rtn_valid, r, t, n = _rtn(a, va, b)
        if rtn_valid
            elevation = _elev_from_rtn(r, t, n)
            avail = avail && (elevation <= cone_deg)
            if avail
                cos_psi = _azim_from_rtn(t, n)
                avail = avail && _azimuth_ok(cos_psi, terminal_id, cone_deg)
                if avail && vb !== nothing
                    duration = _duration(
                        a,
                        va,
                        b,
                        vb;
                        max_range=max_range,
                        time_horizon=time_horizon,
                    )
                    avail = avail && (duration >= min_duration)
                end
            end
        else
            avail = false
        end
    end

    delay = d / SPEED_OF_LIGHT_KM_S * 1000
    return avail, d, delay, los, elevation, cos_psi, duration
end

"""批量评估 (pairs × time)，返回与 evaluate_isl_batch_gpu 对齐的 NamedTuple。"""
function evaluate_isl_series(
    positions, isl_pairs;
    velocities=nothing, kwargs...,
)
    n_pairs = length(isl_pairs)
    n_times = size(positions, 2)
    available = Array{Bool}(undef, n_pairs, n_times)
    distance_km = Array{Float64}(undef, n_pairs, n_times)
    delay_ms = Array{Float64}(undef, n_pairs, n_times)
    line_of_sight = Array{Bool}(undef, n_pairs, n_times)
    elevation_deg = Array{Float64}(undef, n_pairs, n_times)
    cos_psi = Array{Float64}(undef, n_pairs, n_times)
    duration_s = Array{Float64}(undef, n_pairs, n_times)

    for (pair_index, (i, j)) in enumerate(isl_pairs)
        i != j || throw(ArgumentError("ISL pair endpoints must be distinct"))
        for time_index in 1:n_times
            a = (
                positions[i, time_index, 1],
                positions[i, time_index, 2],
                positions[i, time_index, 3],
            )
            b = (
                positions[j, time_index, 1],
                positions[j, time_index, 2],
                positions[j, time_index, 3],
            )
            va = velocities === nothing ? nothing : (
                velocities[i, time_index, 1],
                velocities[i, time_index, 2],
                velocities[i, time_index, 3],
            )
            vb = velocities === nothing ? nothing : (
                velocities[j, time_index, 1],
                velocities[j, time_index, 2],
                velocities[j, time_index, 3],
            )
            avail, d, delay, los, elev, cp, dur =
                evaluate_isl_one(a, b; va=va, vb=vb, kwargs...)
            available[pair_index, time_index] = avail
            distance_km[pair_index, time_index] = d
            delay_ms[pair_index, time_index] = delay
            line_of_sight[pair_index, time_index] = los
            elevation_deg[pair_index, time_index] = elev
            cos_psi[pair_index, time_index] = cp
            duration_s[pair_index, time_index] = dur
        end
    end

    return (
        available=available,
        distance_km=distance_km,
        delay_ms=delay_ms,
        line_of_sight=line_of_sight,
        elevation_deg=elevation_deg,
        cos_psi=cos_psi,
        duration_s=duration_s,
    )
end

end # module

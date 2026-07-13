# ===== 链路评估 =====
# ISL / GSL 物理链路评估，使用 core/geometry.jl + constraints 层。

using LinearAlgebra: norm
using SatelliteToolbox: SatelliteToolbox

export evaluate_isl_batch, evaluate_gsl_batch, evaluate_isl_series

# ═══════════════════════════════════════════════
# ISL 评估
# ═══════════════════════════════════════════════

"""
    evaluate_isl(pos_a, pos_b; constraints, vel_a, vel_b, time_horizon)
        -> (available, distance, los, delay_ms, details)

评估一条 ISL 的物理状态，包含距离、LOS、仰角、方位角、持续时间检查。

返回的 details 是命名元组 (elevation_ok, azimuth_ok, duration_ok, elevation_deg, cos_psi, duration_s)。
"""
function evaluate_isl(
    pos_a::NTuple{3,Real},
    pos_b::NTuple{3,Real};
    constraints::PhysicalConstraints=LEO_DEFAULTS,
    vel_a::Union{NTuple{3,Real},Nothing}=nothing,
    vel_b::Union{NTuple{3,Real},Nothing}=nothing,
    time_horizon::Float64=300.0,
    terminal_id::Int=4,  # 默认使用右侧终端
)
    d = distance_km(pos_a, pos_b)
    los = has_los(pos_a, pos_b)

    # 1. 基本检查（距离 + LOS）
    available = check_isl(d, los; constraints=constraints)

    # 2. 仰角检查（需速度计算 RTN）
    elev_ok = true
    elevation = 90.0
    r = t = n = 0.0
    if available && vel_a !== nothing
        rtn_valid, r, t, n = _try_compute_rtn_coordinates(pos_a, vel_a, pos_b)
        if rtn_valid
            elevation = compute_elevation_from_rtn(r, t, n)
            elev_ok = check_isl_elevation(elevation; constraints=constraints)
        else
            elev_ok = false
        end
        available &= elev_ok
    end

    # 3. 方位角检查（需速度）
    azim_ok = true
    cos_psi = 1.0
    if available && vel_a !== nothing
        cos_psi = compute_azimuth_from_rtn(t, n)
        azim_ok = check_isl_azimuth(cos_psi, terminal_id; constraints=constraints)
        available &= azim_ok
    end

    # 4. 持续时间检查（需双方速度）
    dur_ok = true
    duration = 0.0
    if available && vel_a !== nothing && vel_b !== nothing
        duration = estimate_link_duration(
            pos_a,
            vel_a,
            pos_b,
            vel_b,
            time_horizon;
            constraints=constraints,
        )
        dur_ok = check_isl_duration(duration; constraints=constraints)
        available &= dur_ok
    end

    delay = propagation_delay_ms(d)

    details = (
        elevation_ok=elev_ok, azimuth_ok=azim_ok, duration_ok=dur_ok,
        elevation_deg=elevation, cos_psi=cos_psi, duration_s=duration,
    )

    return available, d, los, delay, details
end

"""
    estimate_link_duration(pos_a, vel_a, pos_b, vel_b, time_horizon) -> Float64

在恒定相对速度直线外推下，解析计算 ISL 首次越过最大距离约束的时刻（秒）。
"""
function estimate_link_duration(
    pos_a::NTuple{3,Real},
    vel_a::NTuple{3,Real},
    pos_b::NTuple{3,Real},
    vel_b::NTuple{3,Real},
    time_horizon::Float64;
    constraints::PhysicalConstraints=LEO_DEFAULTS,
)
    max_range = constraints.isl_max_range_km
    isfinite(max_range) && max_range > 0.0 ||
        throw(ArgumentError("isl_max_range_km must be finite and positive"))
    isfinite(time_horizon) && time_horizon > 0.0 ||
        throw(ArgumentError("time_horizon must be finite and positive"))

    rel_pos = ntuple(i -> Float64(pos_b[i]) - Float64(pos_a[i]), 3)
    rel_vel = ntuple(i -> Float64(vel_b[i]) - Float64(vel_a[i]), 3)
    all(isfinite, rel_pos) && all(isfinite, rel_vel) ||
        throw(ArgumentError("positions and velocities must be finite"))

    position_scale = max(max_range, maximum(abs, rel_pos))
    scaled_position = ntuple(i -> rel_pos[i] / position_scale, 3)
    scaled_range = max_range / position_scale
    scaled_distance = sqrt(sum(abs2, scaled_position))
    range_residual =
        (scaled_distance - scaled_range) * (scaled_distance + scaled_range)
    range_residual > 0.0 && return 0.0

    velocity_scale = maximum(abs, rel_vel)
    velocity_scale == 0.0 && return time_horizon
    scaled_velocity = ntuple(i -> rel_vel[i] / velocity_scale, 3)
    speed_squared = sum(abs2, scaled_velocity)
    radial_rate =
        sum(scaled_position[i] * scaled_velocity[i] for i in 1:3)
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
    return clamp(crossing, 0.0, time_horizon)
end

"""
    evaluate_isl_batch(pos_matrix, isl_pairs; constraints, vel_matrix, time_horizon) -> Vector

批量评估多条 ISL。若有速度矩阵则自动启用激光终端检查。
"""
function evaluate_isl_batch(
    pos_matrix::AbstractMatrix{<:Real},
    isl_pairs::Vector{Tuple{Int,Int}};
    constraints::PhysicalConstraints=LEO_DEFAULTS,
    vel_matrix::Union{AbstractMatrix{<:Real},Nothing}=nothing,
    time_horizon::Float64=300.0,
)
    results = []
    has_vel = vel_matrix !== nothing
    for (i, j) in isl_pairs
        i != j || throw(ArgumentError("ISL pair endpoints must be distinct"))
        a = (pos_matrix[i,1], pos_matrix[i,2], pos_matrix[i,3])
        b = (pos_matrix[j,1], pos_matrix[j,2], pos_matrix[j,3])
        va = has_vel ? (vel_matrix[i,1], vel_matrix[i,2], vel_matrix[i,3]) : nothing
        vb = has_vel ? (vel_matrix[j,1], vel_matrix[j,2], vel_matrix[j,3]) : nothing

        avail, d, los, lat, det = evaluate_isl(
            a, b; constraints=constraints,
            vel_a=va, vel_b=vb, time_horizon=time_horizon,
        )
        push!(results, (
            source_id=i, target_id=j,
            available=avail, distance_km=d,
            line_of_sight=los, latency_ms=lat,
            elevation_deg=det.elevation_deg,
            cos_psi=det.cos_psi, duration_s=det.duration_s,
            elevation_ok=det.elevation_ok,
            azimuth_ok=det.azimuth_ok, duration_ok=det.duration_ok,
        ))
    end
    return results
end

# ═══════════════════════════════════════════════
# GSL 评估
# ═══════════════════════════════════════════════

"""
    evaluate_gsl(sat_ecef, gs_lat, gs_lon, gs_alt; constraints=LEO_DEFAULTS)
        -> (available, distance, elevation, delay_ms)

评估一条 GSL 的物理状态。
"""
function evaluate_gsl(
    sat_ecef::NTuple{3,Real},
    gs_lat::Real, gs_lon::Real, gs_alt::Real;
    constraints::PhysicalConstraints=LEO_DEFAULTS,
)
    gs_ecef = geodetic_to_ecef_km(gs_lat, gs_lon, gs_alt)
    d = distance_km(sat_ecef, gs_ecef)
    el = elevation_deg(sat_ecef, gs_lat, gs_lon, gs_alt)
    available = check_gsl(d, el; constraints=constraints)
    delay = propagation_delay_ms(d)
    return available, d, el, delay
end

"""
    evaluate_gsl_batch(pos_matrix, gs_stations; constraints=LEO_DEFAULTS)
        -> (avail_mat, dist_mat, elev_mat, delay_mat)

批量评估 N 颗卫星对 M 个地面站的 GSL。
"""
function evaluate_gsl_batch(
    pos_matrix::AbstractMatrix{<:Real},
    gs_stations::Vector{NTuple{3,Float64}};
    constraints::PhysicalConstraints=LEO_DEFAULTS,
)
    N = size(pos_matrix, 1)
    M = length(gs_stations)
    avail_mat = zeros(Bool, N, M)
    dist_mat = zeros(N, M)
    elev_mat = zeros(N, M)
    delay_mat = zeros(N, M)

    for i in 1:N
        sat = (pos_matrix[i,1], pos_matrix[i,2], pos_matrix[i,3])
        for (j, (lat, lon, alt)) in enumerate(gs_stations)
            avail, d, el, lat_ms = evaluate_gsl(sat, lat, lon, alt; constraints=constraints)
            avail_mat[i,j] = avail
            dist_mat[i,j] = d
            elev_mat[i,j] = el
            delay_mat[i,j] = lat_ms
        end
    end
    return avail_mat, dist_mat, elev_mat, delay_mat
end

compute_backend_capabilities(::CPUComputeBackend) = (
    operations=(:gsl_series, :isl_series),
    device=:cpu,
    precision=Float64,
    input_residency=:host,
    output_residency=:host,
)

compute_backend_fingerprint(backend::CPUComputeBackend) = (
    name="cpu",
    type=string(typeof(backend)),
    implementation_module="SatelliteSimLink",
    implementation_version=string(Base.pkgversion(@__MODULE__)),
    capabilities=compute_backend_capabilities(backend),
    cache_token=compute_backend_cache_token(backend),
)

compute_backend_cache_token(::CPUComputeBackend) = :cpu

function compute_backend_source_files(::CPUComputeBackend)
    files = String[]
    for (root, _, names) in walkdir(@__DIR__)
        append!(
            files,
            joinpath(root, name) for name in names if endswith(name, ".jl"),
        )
    end
    push!(files, joinpath(@__DIR__, "..", "Project.toml"))
    return sort!(files)
end

function evaluate_gsl_series(
    ::CPUComputeBackend,
    positions::AbstractArray{<:Real,3},
    stations;
    gsl_min_elevation_deg,
    gsl_max_range_km,
)::GSLSeriesResult
    size(positions, 3) == 3 ||
        throw(ArgumentError("positions must have shape (satellite, time, xyz=3)"))
    n_satellites, n_times, _ = size(positions)
    n_satellites > 0 && n_times > 0 ||
        throw(ArgumentError("positions must be non-empty"))
    all(isfinite, positions) ||
        throw(ArgumentError("positions must contain only finite values"))
    isfinite(gsl_min_elevation_deg) ||
        throw(ArgumentError("gsl_min_elevation_deg must be finite"))
    isfinite(gsl_max_range_km) && gsl_max_range_km > 0 ||
        throw(ArgumentError("gsl_max_range_km must be finite and positive"))

    normalized_stations = NTuple{3,Float64}[]
    sizehint!(normalized_stations, length(stations))
    for station in stations
        length(station) == 3 ||
            throw(ArgumentError(
                "each GSL station must be (latitude_deg, longitude_deg, altitude_km)",
            ))
        normalized = Tuple(Float64(value) for value in station)
        all(isfinite, normalized) ||
            throw(ArgumentError("GSL station coordinates must be finite"))
        -90 <= normalized[1] <= 90 ||
            throw(ArgumentError("GSL station latitude must be in [-90, 90] degrees"))
        push!(normalized_stations, normalized)
    end
    constraints = PhysicalConstraints(
        gsl_min_elevation_deg=Float64(gsl_min_elevation_deg),
        gsl_max_range_km=Float64(gsl_max_range_km),
    )
    output_size = (n_satellites, length(normalized_stations), n_times)
    available = Array{Bool}(undef, output_size)
    distance_km = Array{Float64}(undef, output_size)
    elevation_deg = Array{Float64}(undef, output_size)
    delay_ms = Array{Float64}(undef, output_size)

    for time_index in 1:n_times
        available_at_time, distance_at_time, elevation_at_time, delay_at_time =
            evaluate_gsl_batch(
                position_at_instant(positions, time_index),
                normalized_stations;
                constraints=constraints,
            )
        available[:, :, time_index] .= available_at_time
        distance_km[:, :, time_index] .= distance_at_time
        elevation_deg[:, :, time_index] .= elevation_at_time
        delay_ms[:, :, time_index] .= delay_at_time
    end
    return validate_gsl_series_result(
        GSLSeriesResult(
            available,
            distance_km,
            elevation_deg,
            delay_ms,
            Dict{String,Any}("backend" => "cpu"),
        );
        expected_satellites=n_satellites,
        expected_stations=length(normalized_stations),
        expected_times=n_times,
    )
end

"""
    evaluate_isl_series(::CPUComputeBackend, positions, isl_pairs; kwargs...)
        -> ISLSeriesResult

CPU 后端的 ISL 契约实现（对齐 `evaluate_gsl_series` CPU 版）：按时间片循环调用
`evaluate_isl_batch`，把每个时刻返回的 `Vector{NamedTuple}` 拼成 `(n_pairs, n_times)`
的 SoA `ISLSeriesResult`。`positions`/`velocities` 形状 `(satellite, time, xyz=3)`，
ECEF km / (km/s)；`isl_pairs` 是 `(source, target)` 的 1-based 卫星编号序列。不提供
`velocities` 时只做距离 + LOS + 距离约束（elevation=90, cos_psi=1, duration=0）。
`terminal_id`（=4）与地球半径沿用 `evaluate_isl_batch` 默认，与 Kernel 后端一致。
"""
function evaluate_isl_series(
    ::CPUComputeBackend,
    positions::AbstractArray{<:Real,3},
    isl_pairs;
    velocities::Union{Nothing,AbstractArray{<:Real,3}}=nothing,
    isl_max_range_km=5000.0,
    isl_require_los::Bool=true,
    isl_max_cone_angle_deg=60.0,
    isl_min_duration_s=10.0,
    time_horizon_s=300.0,
)::ISLSeriesResult
    size(positions, 3) == 3 ||
        throw(ArgumentError("positions must have shape (satellite, time, xyz=3)"))
    n_satellites, n_times, _ = size(positions)
    n_satellites > 0 && n_times > 0 ||
        throw(ArgumentError("positions must be non-empty"))
    all(isfinite, positions) ||
        throw(ArgumentError("positions must contain only finite values"))

    max_range = Float64(isl_max_range_km)
    cone_angle = Float64(isl_max_cone_angle_deg)
    min_duration = Float64(isl_min_duration_s)
    time_horizon = Float64(time_horizon_s)
    isfinite(max_range) && max_range > 0.0 ||
        throw(ArgumentError("isl_max_range_km must be finite and positive"))
    isfinite(cone_angle) && 0.0 <= cone_angle <= 180.0 ||
        throw(ArgumentError("isl_max_cone_angle_deg must be in [0, 180] degrees"))
    isfinite(min_duration) && min_duration >= 0.0 ||
        throw(ArgumentError("isl_min_duration_s must be finite and non-negative"))
    isfinite(time_horizon) && time_horizon > 0.0 ||
        throw(ArgumentError("time_horizon_s must be finite and positive"))
    if velocities !== nothing
        size(velocities) == size(positions) ||
            throw(ArgumentError(
                "velocities must match positions shape (satellite, time, xyz=3)",
            ))
        all(isfinite, velocities) ||
            throw(ArgumentError("velocities must contain only finite values"))
    end

    pairs = Tuple{Int,Int}[]
    sizehint!(pairs, length(isl_pairs))
    for pair in isl_pairs
        length(pair) == 2 ||
            throw(ArgumentError("each ISL pair must be (source, target)"))
        i, j = Int(first(pair)), Int(last(pair))
        (1 <= i <= n_satellites && 1 <= j <= n_satellites) ||
            throw(ArgumentError("isl_pairs indices must be within 1:$(n_satellites)"))
        i != j || throw(ArgumentError("ISL pair endpoints must be distinct"))
        push!(pairs, (i, j))
    end

    constraints = PhysicalConstraints(
        isl_max_range_km=max_range,
        isl_require_los=isl_require_los,
        isl_max_cone_angle_deg=cone_angle,
        isl_min_duration_s=min_duration,
    )

    n_pairs = length(pairs)
    available = Array{Bool}(undef, n_pairs, n_times)
    distance_km = Array{Float64}(undef, n_pairs, n_times)
    delay_ms = Array{Float64}(undef, n_pairs, n_times)
    line_of_sight = Array{Bool}(undef, n_pairs, n_times)
    elevation_deg = Array{Float64}(undef, n_pairs, n_times)
    cos_psi = Array{Float64}(undef, n_pairs, n_times)
    duration_s = Array{Float64}(undef, n_pairs, n_times)

    for time_index in 1:n_times
        vel_matrix = velocities === nothing ? nothing :
            position_at_instant(velocities, time_index)
        results_at_time = evaluate_isl_batch(
            position_at_instant(positions, time_index),
            pairs;
            constraints=constraints,
            vel_matrix=vel_matrix,
            time_horizon=time_horizon,
        )
        for (pair_index, link) in enumerate(results_at_time)
            available[pair_index, time_index] = link.available
            distance_km[pair_index, time_index] = link.distance_km
            delay_ms[pair_index, time_index] = link.latency_ms
            line_of_sight[pair_index, time_index] = link.line_of_sight
            elevation_deg[pair_index, time_index] = link.elevation_deg
            cos_psi[pair_index, time_index] = link.cos_psi
            duration_s[pair_index, time_index] = link.duration_s
        end
    end

    return validate_isl_series_result(
        ISLSeriesResult(
            available,
            distance_km,
            delay_ms,
            line_of_sight,
            elevation_deg,
            cos_psi,
            duration_s,
            Dict{String,Any}("backend" => "cpu"),
        );
        expected_pairs=n_pairs,
        expected_times=n_times,
    )
end

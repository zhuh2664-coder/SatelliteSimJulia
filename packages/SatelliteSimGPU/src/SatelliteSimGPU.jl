module SatelliteSimGPU

using Adapt
using KernelAbstractions
using ChainRulesCore
using SatelliteSimBackends: AbstractComputeBackend, GSLSeriesResult, ISLSeriesResult,
                            register_compute_backend!, validate_gsl_series_result,
                            validate_isl_series_result
import SatelliteSimBackends: compute_backend_name, compute_backend_capabilities,
                             compute_backend_cache_token, compute_backend_fingerprint,
                             compute_backend_source_files, evaluate_gsl_series,
                             evaluate_isl_series

export coverage_loss_gpu, evaluate_gsl_batch_gpu,
       KernelComputeBackend, register_kernel_compute_backend!

const _SPEED_OF_LIGHT_KM_S = 299_792.458

@inline _wait_event(event) = event === nothing ? nothing : wait(event)

@inline function _elevation_deg_gpu(
    sx::T, sy::T, sz::T,
    gx::T, gy::T, gz::T,
) where T <: AbstractFloat
    dx, dy, dz = sx - gx, sy - gy, sz - gz
    gr = sqrt(gx^2 + gy^2 + gz^2)
    nx, ny, nz = gx / gr, gy / gr, gz / gr
    along_normal = dx * nx + dy * ny + dz * nz
    tx = dx - along_normal * nx
    ty = dy - along_normal * ny
    tz = dz - along_normal * nz
    tangential = sqrt(tx^2 + ty^2 + tz^2 + T(1e-12))
    el_rad = atan(along_normal, tangential)
    return el_rad * T(180.0 / π)
end

@inline function _soft_coverage_gpu(
    elevation_deg::T,
    min_el_deg::T,
    τ::T,
) where T <: AbstractFloat
    z = (elevation_deg - min_el_deg) / τ
    return one(T) / (one(T) + exp(-z))
end

@kernel function _coverage_kernel!(
    step_cov,
    positions,
    ground_pts,
    min_el,
    τ_cov,
    n_satellites,
    n_times,
)
    linear_index = @index(Global)
    ground_index = (linear_index - 1) ÷ n_times + 1
    time_index = (linear_index - 1) % n_times + 1

    gx = ground_pts[ground_index, 1]
    gy = ground_pts[ground_index, 2]
    gz = ground_pts[ground_index, 3]
    p_none = one(eltype(step_cov))

    for satellite_index in 1:n_satellites
        sx = positions[satellite_index, time_index, 1]
        sy = positions[satellite_index, time_index, 2]
        sz = positions[satellite_index, time_index, 3]
        elevation = _elevation_deg_gpu(sx, sy, sz, gx, gy, gz)
        coverage = _soft_coverage_gpu(elevation, min_el, τ_cov)
        p_none *= one(eltype(step_cov)) - coverage
    end

    step_cov[ground_index, time_index] =
        one(eltype(step_cov)) - p_none
end

@kernel function _revisit_kernel!(
    revisit_gaps,
    step_cov,
    weights,
    dt,
    n_times,
)
    ground_index = @index(Global)
    gap = zero(eltype(revisit_gaps))
    one_value = one(eltype(revisit_gaps))

    for time_index in 1:n_times
        coverage = step_cov[ground_index, time_index]
        gap = (gap + dt) * (one_value - coverage)
    end

    revisit_gaps[ground_index] = gap * weights[ground_index]
end

@kernel function _weighted_coverage_kernel!(
    weighted_cov,
    step_cov,
    weights,
)
    linear_index = @index(Global)
    ground_index = (linear_index - 1) ÷ size(step_cov, 2) + 1
    time_index = (linear_index - 1) % size(step_cov, 2) + 1
    weighted_cov[ground_index, time_index] =
        step_cov[ground_index, time_index] * weights[ground_index]
end

function _validate_coverage_inputs(positions, ground_pts, weights)
    size(positions, 3) == 3 ||
        throw(ArgumentError("positions must have shape (N, NT, 3)"))
    size(ground_pts, 2) == 3 ||
        throw(ArgumentError("ground_pts must have shape (G, 3)"))
    size(ground_pts, 1) == length(weights) ||
        throw(ArgumentError("ground_pts and weights must have matching G"))
    size(positions, 1) > 0 &&
        size(positions, 2) > 0 &&
        size(ground_pts, 1) > 0 ||
        throw(ArgumentError("positions and ground_pts must be non-empty"))
    eltype(positions) <: AbstractFloat ||
        throw(ArgumentError("positions eltype must be Float32 or Float64"))
    return nothing
end

"""
    coverage_loss_gpu(
        positions,
        ground_pts,
        weights;
        min_el,
        τ_cov,
        dt,
        τ_revisit,
        λ,
    ) -> scalar

Backend-independent KernelAbstractions implementation of the CPU reference
coverage loss. Inputs are expected to already reside on the selected backend.
"""
function coverage_loss_gpu(
    positions::AbstractArray{T,3},
    ground_pts::AbstractMatrix{T},
    weights::AbstractVector{T};
    min_el::T = T(10.0),
    τ_cov::T = T(5.0),
    dt::T = T(1.0),
    τ_revisit::T = one(T),
    λ::T = T(0.1),
) where T <: Number
    _validate_coverage_inputs(positions, ground_pts, weights)

    n_satellites, n_times, _ = size(positions)
    n_ground = size(ground_pts, 1)
    backend = get_backend(positions)

    step_cov = similar(positions, T, (n_ground, n_times))
    revisit_gaps = similar(positions, T, n_ground)
    weighted_cov = similar(positions, T, (n_ground, n_times))

    _wait_event(_coverage_kernel!(backend)(
        step_cov,
        positions,
        ground_pts,
        min_el,
        τ_cov,
        n_satellites,
        n_times;
        ndrange=n_ground * n_times,
    ))

    _wait_event(_revisit_kernel!(backend)(
        revisit_gaps,
        step_cov,
        weights,
        dt,
        n_times;
        ndrange=n_ground,
    ))

    _wait_event(_weighted_coverage_kernel!(backend)(
        weighted_cov,
        step_cov,
        weights;
        ndrange=n_ground * n_times,
    ))

    total_cov = sum(weighted_cov)
    total_weight = sum(weights)
    mean_cov = total_cov / (total_weight * T(n_times))

    maximum_gap = maximum(revisit_gaps)
    worst_revisit = maximum_gap + τ_revisit * log(
        sum(exp.((revisit_gaps .- maximum_gap) ./ τ_revisit)),
    )

    return -mean_cov + λ * worst_revisit
end

function _validate_gsl_inputs(positions, ground_ecef, ned_rotation)
    size(positions, 3) == 3 ||
        throw(ArgumentError("positions must have shape (N, NT, 3)"))
    size(ground_ecef, 2) == 3 ||
        throw(ArgumentError("ground_ecef must have shape (M, 3)"))
    size(ned_rotation, 1) == size(ground_ecef, 1) &&
        size(ned_rotation, 2) == 3 &&
        size(ned_rotation, 3) == 3 ||
        throw(ArgumentError("ned_rotation must have shape (M, 3, 3)"))
    size(positions, 1) > 0 &&
        size(positions, 2) > 0 &&
        size(ground_ecef, 1) > 0 ||
        throw(ArgumentError("positions and ground_ecef must be non-empty"))
    return nothing
end

@inline function _gsl_elevation_deg_gpu(
    north::T,
    east::T,
    down::T,
) where T <: AbstractFloat
    range = sqrt(north^2 + east^2 + down^2)
    range == zero(T) && return T(90.0)
    nadir = acos(clamp(-down / range, -one(T), one(T)))
    return (T(π / 2) - nadir) * T(180.0 / π)
end

@kernel function _gsl_kernel!(
    available,
    distances,
    elevations,
    delays,
    positions,
    ground_ecef,
    ned_rotation,
    min_elevation,
    max_range,
    speed_of_light,
    milliseconds,
    n_stations,
    n_times,
)
    linear_index = @index(Global)
    linear_index -= 1
    time_index = linear_index % n_times + 1
    station_index = (linear_index ÷ n_times) % n_stations + 1
    satellite_index = linear_index ÷ (n_times * n_stations) + 1

    sx = positions[satellite_index, time_index, 1]
    sy = positions[satellite_index, time_index, 2]
    sz = positions[satellite_index, time_index, 3]
    gx = ground_ecef[station_index, 1]
    gy = ground_ecef[station_index, 2]
    gz = ground_ecef[station_index, 3]
    dx = sx - gx
    dy = sy - gy
    dz = sz - gz

    north =
        ned_rotation[station_index, 1, 1] * dx +
        ned_rotation[station_index, 1, 2] * dy +
        ned_rotation[station_index, 1, 3] * dz
    east =
        ned_rotation[station_index, 2, 1] * dx +
        ned_rotation[station_index, 2, 2] * dy +
        ned_rotation[station_index, 2, 3] * dz
    down =
        ned_rotation[station_index, 3, 1] * dx +
        ned_rotation[station_index, 3, 2] * dy +
        ned_rotation[station_index, 3, 3] * dz

    distance = sqrt(dx^2 + dy^2 + dz^2)
    elevation = _gsl_elevation_deg_gpu(north, east, down)
    available[satellite_index, station_index, time_index] =
        distance <= max_range && elevation >= min_elevation
    distances[satellite_index, station_index, time_index] = distance
    elevations[satellite_index, station_index, time_index] = elevation
    delays[satellite_index, station_index, time_index] =
        distance / speed_of_light * milliseconds
end

"""
    evaluate_gsl_batch_gpu(
        positions,
        ground_ecef,
        ned_rotation;
        gsl_min_elevation_deg,
        gsl_max_range_km,
    ) -> (available, distance_km, elevation_deg, delay_ms)

Evaluate all satellite/ground-station/time GSL links on the selected
KernelAbstractions backend. `positions` has shape `(N, NT, 3)`,
`ground_ecef` has shape `(M, 3)`, and `ned_rotation` has shape `(M, 3, 3)`.
All coordinates are ECEF kilometres. Each station's rotation maps an ECEF
delta vector in kilometres to the station's NED coordinates in kilometres.
The station ECEF coordinates and NED rotations must be precomputed on the
host with the same geodetic convention as the CPU reference.

The returned arrays have shape `(N, M, NT)`. `available` is boolean,
`distance_km`, `elevation_deg`, and `delay_ms` use the input floating-point
element type. The default thresholds match `LEO_DEFAULTS` in the CPU
reference: 25 degrees minimum elevation and 2000 km maximum range.
"""
function evaluate_gsl_batch_gpu(
    positions::AbstractArray{T,3},
    ground_ecef::AbstractMatrix{T},
    ned_rotation::AbstractArray{T,3};
    gsl_min_elevation_deg::T = T(25.0),
    gsl_max_range_km::T = T(2000.0),
) where T <: AbstractFloat
    _validate_gsl_inputs(positions, ground_ecef, ned_rotation)

    n_satellites, n_times, _ = size(positions)
    n_stations = size(ground_ecef, 1)
    backend = get_backend(positions)
    output_size = (n_satellites, n_stations, n_times)
    available = similar(positions, Bool, output_size)
    distances = similar(positions, T, output_size)
    elevations = similar(positions, T, output_size)
    delays = similar(positions, T, output_size)

    _wait_event(_gsl_kernel!(backend)(
        available,
        distances,
        elevations,
        delays,
        positions,
        ground_ecef,
        ned_rotation,
        gsl_min_elevation_deg,
        gsl_max_range_km,
        T(_SPEED_OF_LIGHT_KM_S),
        T(1000.0),
        n_stations,
        n_times;
        ndrange=n_satellites * n_stations * n_times,
    ))

    return available, distances, elevations, delays
end

"""
    KernelComputeBackend(backend; precision=Float64)

Adapter from a `KernelAbstractions.Backend` to the platform compute-backend
contract. Cross-layer inputs and outputs remain host arrays; this adapter owns
the transfers around supported kernels.
"""
struct KernelComputeBackend{
    B<:KernelAbstractions.Backend,
    T<:AbstractFloat,
} <: AbstractComputeBackend
    backend::B
end

function KernelComputeBackend(
    backend::B;
    precision::Type{T}=Float64,
) where {B<:KernelAbstractions.Backend,T<:AbstractFloat}
    return KernelComputeBackend{B,T}(backend)
end

_backend_precision(::KernelComputeBackend{B,T}) where {B,T} = T

compute_backend_name(backend::KernelComputeBackend) =
    "kernel_abstractions/$(nameof(typeof(backend.backend)))"

compute_backend_capabilities(backend::KernelComputeBackend) = (
    operations=(:gsl_series, :isl_series),
    device=KernelAbstractions.isgpu(backend.backend) ? :gpu : :cpu,
    input_residency=:host,
    output_residency=:host,
    precision=_backend_precision(backend),
)

function _module_version(module_)::String
    return try
        version = Base.pkgversion(module_)
        version === nothing ? "unknown" : string(version)
    catch
        "unknown"
    end
end

compute_backend_cache_token(backend::KernelComputeBackend{B,T}) where {B,T} = (
    backend_type=string(B),
    backend_state=repr(backend.backend),
    precision=string(T),
)

function compute_backend_fingerprint(backend::KernelComputeBackend)
    device_module = parentmodule(typeof(backend.backend))
    return (
        name=compute_backend_name(backend),
        type=string(typeof(backend)),
        implementation_module="SatelliteSimGPU",
        implementation_version=_module_version(@__MODULE__),
        kernel_abstractions_version=_module_version(KernelAbstractions),
        device_module=string(device_module),
        device_module_version=_module_version(device_module),
        capabilities=compute_backend_capabilities(backend),
        cache_token=compute_backend_cache_token(backend),
    )
end

function compute_backend_source_files(::KernelComputeBackend)
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

function _compute_precision(options::NamedTuple)
    unknown = setdiff(keys(options), (:precision,))
    isempty(unknown) ||
        throw(ArgumentError("unsupported compute backend options: $(join(unknown, ", "))"))
    value = get(options, :precision, "float64")
    value in ("float32", :float32, 32) && return Float32
    value in ("float64", :float64, 64) && return Float64
    throw(ArgumentError("precision must be float32 or float64"))
end

"""
    register_kernel_compute_backend!(name, backend; replace=false)

Register a loaded GPU backend, for example
`register_kernel_compute_backend!(:cuda, CUDA.CUDABackend())`. The concrete
device package remains optional and is never imported by `SatelliteSimGPU`.
"""
function register_kernel_compute_backend!(
    name::Union{Symbol,AbstractString},
    backend::KernelAbstractions.Backend;
    replace::Bool=false,
)::Symbol
    KernelAbstractions.isgpu(backend) ||
        throw(ArgumentError("registered kernel compute backend must be a GPU backend"))
    return register_compute_backend!(
        name,
        options -> KernelComputeBackend(
            backend;
            precision=_compute_precision(options),
        );
        replace=replace,
    )
end

const _WGS84_FLATTENING = 1 / 298.257223563
const _WGS84_ECCENTRICITY_SQUARED =
    _WGS84_FLATTENING * (2 - _WGS84_FLATTENING)
const _WGS84_EQUATORIAL_RADIUS_KM = 6378.137

function _gsl_station_geometry(stations, ::Type{T}) where T<:AbstractFloat
    n_stations = length(stations)
    ground_ecef = Matrix{T}(undef, n_stations, 3)
    ned_rotation = Array{T}(undef, n_stations, 3, 3)

    for (station_index, station) in enumerate(stations)
        length(station) == 3 ||
            throw(ArgumentError("each GSL station must be (latitude_deg, longitude_deg, altitude_km)"))
        latitude_deg, longitude_deg, altitude_km = station
        all(isfinite, station) ||
            throw(ArgumentError("GSL station coordinates must be finite"))
        -90 <= latitude_deg <= 90 ||
            throw(ArgumentError("GSL station latitude must be in [-90, 90] degrees"))
        latitude = T(deg2rad(latitude_deg))
        longitude = T(deg2rad(longitude_deg))
        altitude = T(altitude_km)
        sin_latitude, cos_latitude = sincos(latitude)
        sin_longitude, cos_longitude = sincos(longitude)
        prime_vertical_radius =
            T(_WGS84_EQUATORIAL_RADIUS_KM) /
            sqrt(one(T) - T(_WGS84_ECCENTRICITY_SQUARED) * sin_latitude^2)

        ground_ecef[station_index, 1] =
            (prime_vertical_radius + altitude) * cos_latitude * cos_longitude
        ground_ecef[station_index, 2] =
            (prime_vertical_radius + altitude) * cos_latitude * sin_longitude
        ground_ecef[station_index, 3] =
            (
                prime_vertical_radius * (one(T) - T(_WGS84_ECCENTRICITY_SQUARED)) +
                altitude
            ) * sin_latitude

        ned_rotation[station_index, 1, 1] = -sin_latitude * cos_longitude
        ned_rotation[station_index, 1, 2] = -sin_latitude * sin_longitude
        ned_rotation[station_index, 1, 3] = cos_latitude
        ned_rotation[station_index, 2, 1] = -sin_longitude
        ned_rotation[station_index, 2, 2] = cos_longitude
        ned_rotation[station_index, 2, 3] = zero(T)
        ned_rotation[station_index, 3, 1] = -cos_latitude * cos_longitude
        ned_rotation[station_index, 3, 2] = -cos_latitude * sin_longitude
        ned_rotation[station_index, 3, 3] = -sin_latitude
    end
    return ground_ecef, ned_rotation
end

function _host_array(array)
    return adapt(Array, array)
end

function evaluate_gsl_series(
    compute_backend::KernelComputeBackend{B,T},
    positions::AbstractArray{<:Real,3},
    stations;
    gsl_min_elevation_deg,
    gsl_max_range_km,
) where {B,T}
    size(positions, 3) == 3 ||
        throw(ArgumentError("positions must have shape (N, NT, 3)"))
    n_satellites, n_times, _ = size(positions)
    n_satellites > 0 && n_times > 0 ||
        throw(ArgumentError("positions must be non-empty"))
    all(isfinite, positions) ||
        throw(ArgumentError("positions must contain only finite values"))
    isfinite(gsl_min_elevation_deg) ||
        throw(ArgumentError("gsl_min_elevation_deg must be finite"))
    isfinite(gsl_max_range_km) && gsl_max_range_km > 0 ||
        throw(ArgumentError("gsl_max_range_km must be finite and positive"))

    n_stations = length(stations)
    metadata = Dict{String,Any}(
        "backend" => compute_backend_name(compute_backend),
        "precision" => string(T),
    )
    if n_stations == 0
        output_size = (n_satellites, 0, n_times)
        return GSLSeriesResult(
            falses(output_size),
            zeros(output_size),
            zeros(output_size),
            zeros(output_size),
            metadata,
        )
    end

    host_positions = Array{T,3}(undef, size(positions))
    host_positions .= positions
    ground_ecef, ned_rotation = _gsl_station_geometry(stations, T)
    device_positions = adapt(compute_backend.backend, host_positions)
    device_ground_ecef = adapt(compute_backend.backend, ground_ecef)
    device_ned_rotation = adapt(compute_backend.backend, ned_rotation)
    device_available, device_distances, device_elevations, device_delays =
        evaluate_gsl_batch_gpu(
            device_positions,
            device_ground_ecef,
            device_ned_rotation;
            gsl_min_elevation_deg=T(gsl_min_elevation_deg),
            gsl_max_range_km=T(gsl_max_range_km),
        )

    result = GSLSeriesResult(
        Array{Bool,3}(_host_array(device_available)),
        Float64.(_host_array(device_distances)),
        Float64.(_host_array(device_elevations)),
        Float64.(_host_array(device_delays)),
        metadata,
    )
    return validate_gsl_series_result(
        result;
        expected_satellites=n_satellites,
        expected_stations=n_stations,
        expected_times=n_times,
    )
end

"""
    evaluate_isl_series(backend::KernelComputeBackend, positions, isl_pairs; kwargs...)
        -> ISLSeriesResult

把 ISL 批量评估接入 `AbstractComputeBackend` 契约（对齐 `evaluate_gsl_series`）。
跨层输入/输出均为 host 数组，本适配器负责设备传输：一次性上传 `positions`
（及可选 `velocities`）到后端设备，调用设备原生核 `evaluate_isl_batch_gpu`，
再把 `(n_pairs, n_times)` 的 SoA 结果下载回 host 并包成 `ISLSeriesResult`。

`positions`/`velocities` 形状 `(N, NT, 3)`，ECEF km / (km/s)；`isl_pairs` 是
`(source, target)` 的 1-based 卫星编号序列。`terminal_id` 与 `earth_radius_km`
沿用 `evaluate_isl_batch_gpu` 默认值（4 / WGS84 赤道半径），与 CPU 后端一致。
"""
function evaluate_isl_series(
    compute_backend::KernelComputeBackend{B,T},
    positions::AbstractArray{<:Real,3},
    isl_pairs;
    velocities::Union{Nothing,AbstractArray{<:Real,3}}=nothing,
    isl_max_range_km=5000.0,
    isl_require_los::Bool=true,
    isl_max_cone_angle_deg=60.0,
    isl_min_duration_s=10.0,
    time_horizon_s=300.0,
) where {B,T}
    size(positions, 3) == 3 ||
        throw(ArgumentError("positions must have shape (N, NT, 3)"))
    n_satellites, n_times, _ = size(positions)
    n_satellites > 0 && n_times > 0 ||
        throw(ArgumentError("positions must be non-empty"))
    all(isfinite, positions) ||
        throw(ArgumentError("positions must contain only finite values"))
    isfinite(isl_max_range_km) && isl_max_range_km > 0 ||
        throw(ArgumentError("isl_max_range_km must be finite and positive"))
    isfinite(isl_max_cone_angle_deg) ||
        throw(ArgumentError("isl_max_cone_angle_deg must be finite"))
    isfinite(isl_min_duration_s) ||
        throw(ArgumentError("isl_min_duration_s must be finite"))
    isfinite(time_horizon_s) && time_horizon_s > 0 ||
        throw(ArgumentError("time_horizon_s must be finite and positive"))
    if velocities !== nothing
        size(velocities) == size(positions) ||
            throw(ArgumentError("velocities must match positions shape (N, NT, 3)"))
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
        push!(pairs, (i, j))
    end

    n_pairs = length(pairs)
    metadata = Dict{String,Any}(
        "backend" => compute_backend_name(compute_backend),
        "precision" => string(T),
    )
    if n_pairs == 0
        output_size = (0, n_times)
        return ISLSeriesResult(
            falses(output_size),
            zeros(output_size),
            zeros(output_size),
            falses(output_size),
            zeros(output_size),
            zeros(output_size),
            zeros(output_size),
            metadata,
        )
    end

    host_positions = Array{T,3}(undef, size(positions))
    host_positions .= positions
    device_positions = adapt(compute_backend.backend, host_positions)
    device_velocities = nothing
    if velocities !== nothing
        host_velocities = Array{T,3}(undef, size(velocities))
        host_velocities .= velocities
        device_velocities = adapt(compute_backend.backend, host_velocities)
    end

    device_result = evaluate_isl_batch_gpu(
        device_positions,
        pairs;
        velocities=device_velocities,
        isl_max_range_km=T(isl_max_range_km),
        isl_require_los=isl_require_los,
        isl_max_cone_angle_deg=T(isl_max_cone_angle_deg),
        isl_min_duration_s=T(isl_min_duration_s),
        time_horizon_s=T(time_horizon_s),
    )

    result = ISLSeriesResult(
        Array{Bool,2}(_host_array(device_result.available)),
        Float64.(_host_array(device_result.distance_km)),
        Float64.(_host_array(device_result.delay_ms)),
        Array{Bool,2}(_host_array(device_result.line_of_sight)),
        Float64.(_host_array(device_result.elevation_deg)),
        Float64.(_host_array(device_result.cos_psi)),
        Float64.(_host_array(device_result.duration_s)),
        metadata,
    )
    return validate_isl_series_result(
        result;
        expected_pairs=n_pairs,
        expected_times=n_times,
    )
end

include("isl.jl")
include("reductions.jl")
include("residency.jl")
include("adjoint.jl")
include("propagator_gpu.jl")
include("frames_gpu.jl")
include("sgp4_gpu.jl")

end

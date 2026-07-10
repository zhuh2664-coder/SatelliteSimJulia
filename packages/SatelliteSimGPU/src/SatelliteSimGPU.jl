module SatelliteSimGPU

using Adapt
using KernelAbstractions

export coverage_loss_gpu, evaluate_gsl_batch_gpu

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

function _validate_inputs(positions, ground_pts, weights)
    ndims(positions) == 3 ||
        throw(ArgumentError("positions must have shape (N, NT, 3)"))
    size(positions, 3) == 3 ||
        throw(ArgumentError("positions must have shape (N, NT, 3)"))
    ndims(ground_pts) == 2 && size(ground_pts, 2) == 3 ||
        throw(ArgumentError("ground_pts must have shape (G, 3)"))
    ndims(weights) == 1 ||
        throw(ArgumentError("weights must have shape (G,)"))
    size(ground_pts, 1) == length(weights) ||
        throw(ArgumentError("ground_pts and weights must have matching G"))
    size(positions, 1) > 0 &&
        size(positions, 2) > 0 &&
        size(ground_pts, 1) > 0 ||
        throw(ArgumentError("positions and ground_pts must be non-empty"))
    eltype(positions) <: AbstractFloat ||
        throw(ArgumentError("positions eltype must be Float32 or Float64"))
    eltype(ground_pts) == eltype(positions) ||
        throw(ArgumentError("ground_pts and positions must have the same eltype"))
    eltype(weights) == eltype(positions) ||
        throw(ArgumentError("weights and positions must have the same eltype"))
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
    _validate_inputs(positions, ground_pts, weights)

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
    ndims(positions) == 3 && size(positions, 3) == 3 ||
        throw(ArgumentError("positions must have shape (N, NT, 3)"))
    ndims(ground_ecef) == 2 && size(ground_ecef, 2) == 3 ||
        throw(ArgumentError("ground_ecef must have shape (M, 3)"))
    ndims(ned_rotation) == 3 &&
        size(ned_rotation, 1) == size(ground_ecef, 1) &&
        size(ned_rotation, 2) == 3 &&
        size(ned_rotation, 3) == 3 ||
        throw(ArgumentError("ned_rotation must have shape (M, 3, 3)"))
    size(positions, 1) > 0 &&
        size(positions, 2) > 0 &&
        size(ground_ecef, 1) > 0 ||
        throw(ArgumentError("positions and ground_ecef must be non-empty"))
    eltype(positions) <: AbstractFloat ||
        throw(ArgumentError("positions eltype must be Float32 or Float64"))
    eltype(ground_ecef) == eltype(positions) ||
        throw(ArgumentError("ground_ecef and positions must have the same eltype"))
    eltype(ned_rotation) == eltype(positions) ||
        throw(ArgumentError("ned_rotation and positions must have the same eltype"))
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

end

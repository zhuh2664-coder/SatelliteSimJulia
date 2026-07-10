module SatelliteSimGPU

using Adapt
using KernelAbstractions

export coverage_loss_gpu, evaluate_gsl_batch_gpu, independent_positions_gpu

const _SPEED_OF_LIGHT_KM_S = 299_792.458
const _EARTH_RADIUS_M = 6_378_137.0
const _EARTH_MU_M3_S2 = 3.986004415e14
const _EARTH_J2 = 0.0010826261738522227
const _EARTH_J4 = -1.6198975999169731e-6
const _NORMALIZED_MU = sqrt(_EARTH_MU_M3_S2 / _EARTH_RADIUS_M^3)
const _SUPPORTED_PROPAGATORS = (:two_body, :j2, :j4)

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

@inline function _propagator_code(propagator::Symbol)
    propagator === :two_body && return Int32(0)
    propagator === :j2 && return Int32(1)
    propagator === :j4 && return Int32(2)
    throw(ArgumentError(
        "unsupported propagator :$propagator; expected one of " *
        join(":" .* String.(_SUPPORTED_PROPAGATORS), ", "),
    ))
end

function _validate_orbit_inputs(orbital_elements, times, ecef_rotation)
    ndims(orbital_elements) == 2 && size(orbital_elements, 2) == 6 ||
        throw(ArgumentError("orbital_elements must have shape (N, 6)"))
    ndims(times) == 1 ||
        throw(ArgumentError("times must have shape (NT,)"))
    ndims(ecef_rotation) == 3 &&
        size(ecef_rotation, 1) == length(times) &&
        size(ecef_rotation, 2) == 3 &&
        size(ecef_rotation, 3) == 3 ||
        throw(ArgumentError("ecef_rotation must have shape (NT, 3, 3)"))
    size(orbital_elements, 1) > 0 && length(times) > 0 ||
        throw(ArgumentError("orbital_elements and times must be non-empty"))
    eltype(orbital_elements) <: AbstractFloat ||
        throw(ArgumentError("orbital_elements eltype must be Float32 or Float64"))
    eltype(times) == eltype(orbital_elements) ||
        throw(ArgumentError("times and orbital_elements must have the same eltype"))
    eltype(ecef_rotation) == eltype(orbital_elements) ||
        throw(ArgumentError(
            "ecef_rotation and orbital_elements must have the same eltype",
        ))

    backend_type = typeof(get_backend(orbital_elements))
    typeof(get_backend(times)) == backend_type &&
        typeof(get_backend(ecef_rotation)) == backend_type ||
        throw(ArgumentError("all orbit inputs must reside on the same backend"))
    all(isfinite, orbital_elements) ||
        throw(ArgumentError("orbital_elements must be finite"))
    all(isfinite, times) ||
        throw(ArgumentError("times must be finite"))
    all(isfinite, ecef_rotation) ||
        throw(ArgumentError("ecef_rotation must be finite"))

    semi_major_axes = @view orbital_elements[:, 1]
    eccentricities = @view orbital_elements[:, 2]
    minimum(semi_major_axes) > zero(eltype(orbital_elements)) ||
        throw(ArgumentError("semi-major axes must be positive"))
    minimum(eccentricities) >= zero(eltype(orbital_elements)) &&
        maximum(eccentricities) < one(eltype(orbital_elements)) ||
        throw(ArgumentError("eccentricities must be in [0, 1)"))
    return nothing
end

@inline function _true_to_mean_anomaly_gpu(e::T, true_anomaly::T) where T <: AbstractFloat
    half_anomaly = true_anomaly / T(2)
    eccentric_anomaly = T(2) * atan(
        sqrt(one(T) - e) * sin(half_anomaly),
        sqrt(one(T) + e) * cos(half_anomaly),
    )
    return eccentric_anomaly - e * sin(eccentric_anomaly)
end

@inline function _mean_to_true_anomaly_gpu(
    e::T,
    mean_anomaly::T,
) where T <: AbstractFloat
    normalized_mean = mod(mean_anomaly, T(2π))
    eccentric_anomaly = e < T(0.8) ? normalized_mean : T(π)
    for _ in 1:20
        sine, cosine = sincos(eccentric_anomaly)
        residual = eccentric_anomaly - e * sine - normalized_mean
        correction = residual / (one(T) - e * cosine)
        eccentric_anomaly -= correction
        abs(correction) <= T(8) * eps(T) && break
    end
    sine, cosine = sincos(eccentric_anomaly)
    denominator = one(T) - e * cosine
    sin_f = sqrt(one(T) - e^2) * sine / denominator
    cos_f = (cosine - e) / denominator
    return atan(sin_f, cos_f)
end

@inline function _secular_rates_gpu(
    semi_major_axis::T,
    eccentricity::T,
    inclination::T,
    propagator_code::Int32,
) where T <: AbstractFloat
    normalized_a = semi_major_axis / T(_EARTH_RADIUS_M)
    eccentricity2 = eccentricity^2
    parameter = normalized_a * (one(T) - eccentricity2)
    parameter2 = parameter^2
    n0 = T(_NORMALIZED_MU) / sqrt(normalized_a^3)
    propagator_code == Int32(0) &&
        return n0, zero(T), zero(T)

    sin_i, cos_i = sincos(inclination)
    sin_i2 = sin_i^2
    beta2 = one(T) - eccentricity2
    beta = sqrt(beta2)
    kn2 = T(_EARTH_J2) / parameter2 * beta

    if propagator_code == Int32(1)
        mean_motion = n0 * (
            one(T) + T(3) / T(4) * kn2 * (T(2) - T(3) * sin_i2)
        )
        k2_bar = mean_motion * T(_EARTH_J2) / parameter2
        raan_rate = -T(3) / T(2) * k2_bar * cos_i
        argp_rate = T(3) / T(4) * k2_bar * (T(4) - T(5) * sin_i2)
        return mean_motion, raan_rate, argp_rate
    end

    parameter4 = parameter^4
    sin_i4 = sin_i^4
    cos_i4 = cos_i^4
    j2_squared = T(_EARTH_J2)^2
    kn22 = j2_squared / parameter4 * beta
    kn4 = T(_EARTH_J4) / parameter4 * beta
    mean_motion = n0 * (
        one(T) +
        T(3) / T(4) * kn2 * (T(2) - T(3) * sin_i2) +
        T(3) / T(128) * kn22 * (
            T(120) + T(64) * beta - T(40) * beta2 +
            (-T(240) - T(192) * beta + T(40) * beta2) * sin_i2 +
            (T(105) + T(144) * beta + T(25) * beta2) * sin_i4
        ) -
        T(45) / T(128) * kn4 * eccentricity2 * (
            -T(8) + T(40) * sin_i2 - T(35) * sin_i4
        )
    )

    k2_bar = mean_motion * T(_EARTH_J2) / parameter2
    k22_bar = mean_motion * j2_squared / parameter4
    k22 = n0 * j2_squared / parameter4
    k4 = n0 * T(_EARTH_J4) / parameter4
    raan_rate =
        -T(3) / T(2) * k2_bar * cos_i +
        T(3) / T(32) * k22_bar * cos_i * (
            -T(36) - T(4) * eccentricity2 + T(48) * beta +
            (T(40) - T(5) * eccentricity2 - T(72) * beta) * sin_i2
        ) +
        T(15) / T(32) * k4 * cos_i * (
            T(8) + T(12) * eccentricity2 -
            (T(14) + T(21) * eccentricity2) * sin_i2
        )
    argp_rate =
        T(3) / T(4) * k2_bar * (T(4) - T(5) * sin_i2) +
        T(3) / T(128) * k22_bar * (
            T(384) + T(96) * eccentricity2 - T(384) * beta +
            (-T(824) - T(116) * eccentricity2 + T(1056) * beta) * sin_i2 +
            (T(430) - T(5) * eccentricity2 - T(720) * beta) * sin_i4
        ) -
        T(15) / T(16) * k22 * eccentricity2 * cos_i4 -
        T(15) / T(128) * k4 * (
            T(64) + T(72) * eccentricity2 -
            (T(248) + T(252) * eccentricity2) * sin_i2 +
            (T(196) + T(189) * eccentricity2) * sin_i4
        )
    return mean_motion, raan_rate, argp_rate
end

@kernel function _orbit_coefficients_kernel!(
    mean_motion,
    raan_rate,
    argp_rate,
    initial_mean_anomaly,
    orbital_elements,
    propagator_code,
)
    satellite_index = @index(Global)
    semi_major_axis = orbital_elements[satellite_index, 1]
    eccentricity = orbital_elements[satellite_index, 2]
    inclination = orbital_elements[satellite_index, 3]
    true_anomaly = orbital_elements[satellite_index, 6]

    mean_motion_value, raan_rate_value, argp_rate_value = _secular_rates_gpu(
        semi_major_axis,
        eccentricity,
        inclination,
        propagator_code,
    )
    mean_motion[satellite_index] = mean_motion_value
    raan_rate[satellite_index] = raan_rate_value
    argp_rate[satellite_index] = argp_rate_value
    initial_mean_anomaly[satellite_index] =
        _true_to_mean_anomaly_gpu(eccentricity, true_anomaly)
end

@kernel function _orbit_positions_kernel!(
    positions,
    orbital_elements,
    times,
    ecef_rotation,
    mean_motion,
    raan_rate,
    argp_rate,
    initial_mean_anomaly,
    n_times,
)
    linear_index = @index(Global)
    linear_index -= 1
    time_index = linear_index % n_times + 1
    satellite_index = linear_index ÷ n_times + 1

    semi_major_axis = orbital_elements[satellite_index, 1]
    eccentricity = orbital_elements[satellite_index, 2]
    inclination = orbital_elements[satellite_index, 3]
    initial_raan = orbital_elements[satellite_index, 4]
    initial_argp = orbital_elements[satellite_index, 5]
    elapsed_s = times[time_index]

    true_anomaly = _mean_to_true_anomaly_gpu(
        eccentricity,
        initial_mean_anomaly[satellite_index] +
        mean_motion[satellite_index] * elapsed_s,
    )
    raan = mod(
        initial_raan + raan_rate[satellite_index] * elapsed_s,
        eltype(positions)(2π),
    )
    argument_of_perigee = mod(
        initial_argp + argp_rate[satellite_index] * elapsed_s,
        eltype(positions)(2π),
    )
    radius = semi_major_axis * (one(eltype(positions)) - eccentricity^2) / (
        one(eltype(positions)) + eccentricity * cos(true_anomaly)
    )
    argument_of_latitude = argument_of_perigee + true_anomaly
    sin_raan, cos_raan = sincos(raan)
    sin_u, cos_u = sincos(argument_of_latitude)
    sin_i, cos_i = sincos(inclination)

    eci_x = radius * (
        cos_raan * cos_u - sin_raan * sin_u * cos_i
    )
    eci_y = radius * (
        sin_raan * cos_u + cos_raan * sin_u * cos_i
    )
    eci_z = radius * sin_u * sin_i
    positions[satellite_index, time_index, 1] = (
        ecef_rotation[time_index, 1, 1] * eci_x +
        ecef_rotation[time_index, 1, 2] * eci_y +
        ecef_rotation[time_index, 1, 3] * eci_z
    ) / eltype(positions)(1000)
    positions[satellite_index, time_index, 2] = (
        ecef_rotation[time_index, 2, 1] * eci_x +
        ecef_rotation[time_index, 2, 2] * eci_y +
        ecef_rotation[time_index, 2, 3] * eci_z
    ) / eltype(positions)(1000)
    positions[satellite_index, time_index, 3] = (
        ecef_rotation[time_index, 3, 1] * eci_x +
        ecef_rotation[time_index, 3, 2] * eci_y +
        ecef_rotation[time_index, 3, 3] * eci_z
    ) / eltype(positions)(1000)
end

"""
    independent_positions_gpu(
        orbital_elements,
        times,
        ecef_rotation;
        propagator=:two_body,
    ) -> positions

Backend-independent KernelAbstractions implementation of the JuliaSpace
backend's independent secular-element propagation. `orbital_elements` has
shape `(N, 6)` with columns `(a_m, e, i_rad, Ω_rad, ω_rad, f_rad)`, `times`
has shape `(NT,)` in seconds, and `ecef_rotation` has shape `(NT, 3, 3)`.
Each rotation is the official SatelliteToolbox TEME-to-PEF matrix for the
corresponding time. All three arrays must already reside on the same backend.

The output has shape `(N, NT, 3)` and contains ECEF positions in kilometres.
Supported propagators are `:two_body`, `:j2`, and `:j4`.
"""
function independent_positions_gpu(
    orbital_elements::AbstractMatrix{T},
    times::AbstractVector{T},
    ecef_rotation::AbstractArray{T,3};
    propagator::Symbol = :two_body,
) where T <: AbstractFloat
    _validate_orbit_inputs(orbital_elements, times, ecef_rotation)
    propagator_code = _propagator_code(propagator)
    n_satellites = size(orbital_elements, 1)
    n_times = length(times)
    backend = get_backend(orbital_elements)

    mean_motion = similar(orbital_elements, T, n_satellites)
    raan_rate = similar(orbital_elements, T, n_satellites)
    argp_rate = similar(orbital_elements, T, n_satellites)
    initial_mean_anomaly = similar(orbital_elements, T, n_satellites)
    positions = similar(orbital_elements, T, (n_satellites, n_times, 3))

    _wait_event(_orbit_coefficients_kernel!(backend)(
        mean_motion,
        raan_rate,
        argp_rate,
        initial_mean_anomaly,
        orbital_elements,
        propagator_code;
        ndrange=n_satellites,
    ))
    _wait_event(_orbit_positions_kernel!(backend)(
        positions,
        orbital_elements,
        times,
        ecef_rotation,
        mean_motion,
        raan_rate,
        argp_rate,
        initial_mean_anomaly,
        n_times;
        ndrange=n_satellites * n_times,
    ))
    return positions
end

end

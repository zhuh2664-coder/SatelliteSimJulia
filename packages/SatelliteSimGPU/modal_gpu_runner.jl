using Pkg
# Ensure the pinned manifest deps are present in the container depot before load.
# No-op when already instantiated; guarded so a working image is never broken.
try
    Pkg.instantiate()
catch instantiate_error
    @warn "Pkg.instantiate failed; attempting to load anyway" exception = instantiate_error
end

using Adapt
using CUDA
using ChainRulesCore
using KernelAbstractions
using Random
using SatelliteSimBackends
using SatelliteSimGPU
using SatelliteToolboxSgp4: sgp4_init, sgp4!, sgp4c_wgs84

const EARTH_RADIUS_KM = 6378.137
const SPEED_OF_LIGHT_KM_S = 299_792.458
const EXPECTED_CUDA_JL_VERSION = v"6.2.1"

function random_positions(n_satellites::Int, n_times::Int, ::Type{T}) where T
    positions = Array{T}(undef, n_satellites, n_times, 3)
    for satellite_index in 1:n_satellites, time_index in 1:n_times
        direction = randn(T, 3)
        direction ./= sqrt(sum(abs2, direction))
        radius = T(6900) + T(100) * rand(T)
        positions[satellite_index, time_index, :] .= radius .* direction
    end
    return positions
end

function random_kepler_elements(n_satellites::Int, ::Type{T}; seed::Int) where T
    Random.seed!(seed)
    semi_major_axis_km = T.(6771 .+ 400 .* rand(n_satellites))
    eccentricity = T.(0.0005 .+ 0.02 .* rand(n_satellites))
    inclination_rad = T.(deg2rad.(30 .+ 120 .* rand(n_satellites)))
    raan_rad = T.(deg2rad.(360 .* rand(n_satellites)))
    argument_of_perigee_rad = T.(deg2rad.(360 .* rand(n_satellites)))
    true_anomaly_rad = T.(deg2rad.(360 .* rand(n_satellites)))
    return (
        semi_major_axis_km,
        eccentricity,
        inclination_rad,
        raan_rad,
        argument_of_perigee_rad,
        true_anomaly_rad,
    )
end

function ground_grid(n_latitudes::Int, n_longitudes::Int, ::Type{T}) where T
    latitudes = range(T(deg2rad(-70)), T(deg2rad(70)); length=n_latitudes)
    longitudes =
        range(T(deg2rad(-180)), T(deg2rad(180)); length=n_longitudes + 1)[1:end-1]
    points = Matrix{T}(undef, n_latitudes * n_longitudes, 3)
    weights = Vector{T}(undef, n_latitudes * n_longitudes)

    point_index = 1
    for latitude in latitudes, longitude in longitudes
        cos_latitude = cos(latitude)
        points[point_index, 1] = T(EARTH_RADIUS_KM) * cos_latitude * cos(longitude)
        points[point_index, 2] = T(EARTH_RADIUS_KM) * cos_latitude * sin(longitude)
        points[point_index, 3] = T(EARTH_RADIUS_KM) * sin(latitude)
        weights[point_index] = cos_latitude
        point_index += 1
    end
    return points, weights
end

@inline function elevation_deg(
    satellite_x::T,
    satellite_y::T,
    satellite_z::T,
    ground_x::T,
    ground_y::T,
    ground_z::T,
) where T
    delta_x = satellite_x - ground_x
    delta_y = satellite_y - ground_y
    delta_z = satellite_z - ground_z
    ground_radius = sqrt(ground_x^2 + ground_y^2 + ground_z^2)
    normal_x = ground_x / ground_radius
    normal_y = ground_y / ground_radius
    normal_z = ground_z / ground_radius
    normal_distance =
        delta_x * normal_x + delta_y * normal_y + delta_z * normal_z
    tangent_x = delta_x - normal_distance * normal_x
    tangent_y = delta_y - normal_distance * normal_y
    tangent_z = delta_z - normal_distance * normal_z
    tangent_distance =
        sqrt(tangent_x^2 + tangent_y^2 + tangent_z^2 + T(1e-12))
    return atan(normal_distance, tangent_distance) * T(180 / π)
end

function coverage_reference(
    positions::AbstractArray{T,3},
    ground_points::AbstractMatrix{T},
    weights::AbstractVector{T};
    minimum_elevation::T=T(10),
    coverage_temperature::T=T(5),
    time_step::T=one(T),
    revisit_temperature::T=one(T),
    revisit_weight::T=T(0.1),
) where T
    n_satellites, n_times, _ = size(positions)
    revisit_gaps = Vector{T}(undef, size(ground_points, 1))
    total_coverage = zero(T)
    total_weight = zero(T)

    for ground_index in axes(ground_points, 1)
        ground_x = ground_points[ground_index, 1]
        ground_y = ground_points[ground_index, 2]
        ground_z = ground_points[ground_index, 3]
        weight = weights[ground_index]
        gap = zero(T)

        for time_index in 1:n_times
            probability_none = one(T)
            for satellite_index in 1:n_satellites
                elevation = elevation_deg(
                    positions[satellite_index, time_index, 1],
                    positions[satellite_index, time_index, 2],
                    positions[satellite_index, time_index, 3],
                    ground_x,
                    ground_y,
                    ground_z,
                )
                coverage =
                    one(T) /
                    (
                        one(T) +
                        exp(-(elevation - minimum_elevation) / coverage_temperature)
                    )
                probability_none *= one(T) - coverage
            end
            step_coverage = one(T) - probability_none
            total_coverage += step_coverage * weight
            total_weight += weight
            gap = (gap + time_step) * (one(T) - step_coverage)
        end
        revisit_gaps[ground_index] = gap * weight
    end

    mean_coverage = total_coverage / total_weight
    maximum_gap = maximum(revisit_gaps)
    worst_revisit =
        maximum_gap +
        revisit_temperature *
        log(sum(exp.((revisit_gaps .- maximum_gap) ./ revisit_temperature)))
    return -mean_coverage + revisit_weight * worst_revisit
end

function station_geometry(n_stations::Int, ::Type{T}) where T
    ground_ecef = Matrix{T}(undef, n_stations, 3)
    ned_rotation = Array{T}(undef, n_stations, 3, 3)
    latitudes = range(T(deg2rad(-65)), T(deg2rad(65)); length=n_stations)

    for station_index in 1:n_stations
        latitude = latitudes[station_index]
        longitude = T(deg2rad(mod(47 * station_index + 11, 360) - 180))
        sin_latitude, cos_latitude = sincos(latitude)
        sin_longitude, cos_longitude = sincos(longitude)

        ground_ecef[station_index, 1] =
            T(EARTH_RADIUS_KM) * cos_latitude * cos_longitude
        ground_ecef[station_index, 2] =
            T(EARTH_RADIUS_KM) * cos_latitude * sin_longitude
        ground_ecef[station_index, 3] = T(EARTH_RADIUS_KM) * sin_latitude

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

function station_tuples(n_stations::Int)
    latitudes = range(-65.0, 65.0; length=n_stations)
    return [
        (latitudes[index], Float64(mod(47 * index + 11, 360) - 180), 0.0)
        for index in 1:n_stations
    ]
end

function gsl_reference(
    positions::AbstractArray{T,3},
    ground_ecef::AbstractMatrix{T},
    ned_rotation::AbstractArray{T,3};
    minimum_elevation::T=T(25),
    maximum_range::T=T(2000),
) where T
    n_satellites, n_times, _ = size(positions)
    n_stations = size(ground_ecef, 1)
    output_size = (n_satellites, n_stations, n_times)
    available = Array{Bool}(undef, output_size)
    distances = Array{T}(undef, output_size)
    elevations = Array{T}(undef, output_size)
    delays = Array{T}(undef, output_size)

    for satellite_index in 1:n_satellites
        for station_index in 1:n_stations, time_index in 1:n_times
            delta_x =
                positions[satellite_index, time_index, 1] -
                ground_ecef[station_index, 1]
            delta_y =
                positions[satellite_index, time_index, 2] -
                ground_ecef[station_index, 2]
            delta_z =
                positions[satellite_index, time_index, 3] -
                ground_ecef[station_index, 3]
            north =
                ned_rotation[station_index, 1, 1] * delta_x +
                ned_rotation[station_index, 1, 2] * delta_y +
                ned_rotation[station_index, 1, 3] * delta_z
            east =
                ned_rotation[station_index, 2, 1] * delta_x +
                ned_rotation[station_index, 2, 2] * delta_y +
                ned_rotation[station_index, 2, 3] * delta_z
            down =
                ned_rotation[station_index, 3, 1] * delta_x +
                ned_rotation[station_index, 3, 2] * delta_y +
                ned_rotation[station_index, 3, 3] * delta_z
            distance = sqrt(delta_x^2 + delta_y^2 + delta_z^2)
            local_range = sqrt(north^2 + east^2 + down^2)
            elevation =
                local_range == zero(T) ?
                T(90) :
                (T(π / 2) - acos(clamp(-down / local_range, -one(T), one(T)))) *
                T(180 / π)

            available[satellite_index, station_index, time_index] =
                distance <= maximum_range && elevation >= minimum_elevation
            distances[satellite_index, station_index, time_index] = distance
            elevations[satellite_index, station_index, time_index] = elevation
            delays[satellite_index, station_index, time_index] =
                distance / T(SPEED_OF_LIGHT_KM_S) * T(1000)
        end
    end
    return available, distances, elevations, delays
end

# ── ISL scalar reference (self-contained; mirrors src/isl.jl semantics) ──────

function isl_scenario(n_satellites::Int, n_times::Int, ::Type{T}; seed::Int=0) where T
    Random.seed!(seed)
    positions = Array{T}(undef, n_satellites, n_times, 3)
    velocities = Array{T}(undef, n_satellites, n_times, 3)
    for satellite_index in 1:n_satellites, time_index in 1:n_times
        direction = randn(T, 3)
        direction ./= sqrt(sum(abs2, direction))
        radius = T(6871) + T(80) * rand(T)
        positions[satellite_index, time_index, :] .= radius .* direction
        velocity_direction = randn(T, 3)
        velocity_direction ./= sqrt(sum(abs2, velocity_direction))
        velocities[satellite_index, time_index, :] .= T(7.6) .* velocity_direction
    end
    return positions, velocities
end

function make_pairs(n_satellites::Int, n_pairs::Int)
    pairs = Vector{Tuple{Int,Int}}()
    stride = 1
    while length(pairs) < n_pairs && stride < n_satellites
        for i in 1:n_satellites
            length(pairs) >= n_pairs && break
            j = mod(i - 1 + stride, n_satellites) + 1
            i == j && continue
            push!(pairs, (i, j))
        end
        stride += 1
    end
    return pairs
end

@inline function _isl_has_los(ax, ay, az, bx, by, bz, earth_radius)
    sx, sy, sz = bx - ax, by - ay, bz - az
    s2 = sx * sx + sy * sy + sz * sz
    s2 == 0 && return sqrt(ax^2 + ay^2 + az^2) >= earth_radius
    t = clamp(-(ax * sx + ay * sy + az * sz) / s2, 0.0, 1.0)
    cx, cy, cz = ax + t * sx, ay + t * sy, az + t * sz
    return sqrt(cx^2 + cy^2 + cz^2) >= earth_radius
end

function isl_reference(
    positions::AbstractArray{T,3},
    pairs::AbstractVector{<:Tuple{Integer,Integer}};
    velocities::Union{Nothing,AbstractArray{T,3}}=nothing,
    max_range::Float64=5000.0,
    require_los::Bool=true,
    cone_deg::Float64=60.0,
    min_duration::Float64=10.0,
    time_horizon::Float64=300.0,
    terminal_id::Int=4,
    earth_radius::Float64=EARTH_RADIUS_KM,
) where T
    n_pairs = length(pairs)
    n_times = size(positions, 2)
    available = Array{Bool}(undef, n_pairs, n_times)
    distance_km = Array{Float64}(undef, n_pairs, n_times)
    delay_ms = Array{Float64}(undef, n_pairs, n_times)
    line_of_sight = Array{Bool}(undef, n_pairs, n_times)
    elevation_deg_out = Array{Float64}(undef, n_pairs, n_times)
    cos_psi_out = Array{Float64}(undef, n_pairs, n_times)
    duration_s = Array{Float64}(undef, n_pairs, n_times)
    cos_rho = cos(deg2rad(cone_deg))

    for (pair_index, (i, j)) in enumerate(pairs)
        for time_index in 1:n_times
            ax = Float64(positions[i, time_index, 1])
            ay = Float64(positions[i, time_index, 2])
            az = Float64(positions[i, time_index, 3])
            bx = Float64(positions[j, time_index, 1])
            by = Float64(positions[j, time_index, 2])
            bz = Float64(positions[j, time_index, 3])
            d = sqrt((ax - bx)^2 + (ay - by)^2 + (az - bz)^2)
            los = _isl_has_los(ax, ay, az, bx, by, bz, earth_radius)
            avail = (d <= max_range) && (!require_los || los)

            elevation = 90.0
            cos_psi = 1.0
            duration = 0.0
            if velocities !== nothing && avail
                vax = Float64(velocities[i, time_index, 1])
                vay = Float64(velocities[i, time_index, 2])
                vaz = Float64(velocities[i, time_index, 3])
                vbx = Float64(velocities[j, time_index, 1])
                vby = Float64(velocities[j, time_index, 2])
                vbz = Float64(velocities[j, time_index, 3])
                ra = sqrt(ax^2 + ay^2 + az^2)
                rx, ry, rz = ax / ra, ay / ra, az / ra
                rv = sqrt(vax^2 + vay^2 + vaz^2)
                tx, ty, tz = vax / rv, vay / rv, vaz / rv
                nx = ry * tz - rz * ty
                ny = rz * tx - rx * tz
                nz = rx * ty - ry * tx
                rn = sqrt(nx^2 + ny^2 + nz^2)
                nx, ny, nz = nx / rn, ny / rn, nz / rn
                relx, rely, relz = bx - ax, by - ay, bz - az
                r = relx * rx + rely * ry + relz * rz
                tcoord = relx * tx + rely * ty + relz * tz
                ncoord = relx * nx + rely * ny + relz * nz
                dist_rtn = sqrt(r^2 + tcoord^2 + ncoord^2)
                elevation = dist_rtn < 1e-10 ? 90.0 : rad2deg(asin(abs(r) / dist_rtn))
                avail = avail && (elevation <= cone_deg)
                if avail
                    denom = sqrt(ncoord^2 + tcoord^2)
                    cos_psi = denom < 1e-10 ? 1.0 : ncoord / denom
                    azimuth_ok =
                        terminal_id == 4 ? cos_psi >= cos_rho :
                        terminal_id == 3 ? cos_psi <= -cos_rho :
                        terminal_id == 1 ? cos_psi > 0 :
                        terminal_id == 2 ? cos_psi < 0 : true
                    avail = avail && azimuth_ok
                    if avail
                        rpx, rpy, rpz = bx - ax, by - ay, bz - az
                        rvx, rvy, rvz = vbx - vax, vby - vay, vbz - vaz
                        duration = time_horizon
                        tt = 1.0
                        while tt <= time_horizon
                            px = rpx + tt * rvx
                            py = rpy + tt * rvy
                            pz = rpz + tt * rvz
                            if sqrt(px^2 + py^2 + pz^2) > max_range
                                duration = tt
                                break
                            end
                            tt += 1.0
                        end
                        avail = avail && (duration >= min_duration)
                    end
                end
            end

            available[pair_index, time_index] = avail
            distance_km[pair_index, time_index] = d
            delay_ms[pair_index, time_index] = d / SPEED_OF_LIGHT_KM_S * 1000
            line_of_sight[pair_index, time_index] = los
            elevation_deg_out[pair_index, time_index] = elevation
            cos_psi_out[pair_index, time_index] = cos_psi
            duration_s[pair_index, time_index] = duration
        end
    end

    return (
        available=available,
        distance_km=distance_km,
        delay_ms=delay_ms,
        line_of_sight=line_of_sight,
        elevation_deg=elevation_deg_out,
        cos_psi=cos_psi_out,
        duration_s=duration_s,
    )
end

# ── error helpers ────────────────────────────────────────────────────────────

function relative_error(actual, expected)
    return maximum(abs.(actual .- expected) ./ max.(abs.(expected), eps(eltype(expected))))
end

function elementwise_isapprox(actual, expected; rtol, atol)
    size(actual) == size(expected) || return false
    return all(
        isapprox(actual_value, expected_value; rtol=rtol, atol=atol)
        for (actual_value, expected_value) in zip(actual, expected)
    )
end

# Streaming max relative error over two arrays (no large temporaries).
function max_rel_error(actual::AbstractArray, expected::AbstractArray)
    m = 0.0
    @inbounds for index in eachindex(actual, expected)
        a = Float64(actual[index])
        b = Float64(expected[index])
        d = abs(a - b) / max(abs(b), eps(Float64))
        d > m && (m = d)
    end
    return m
end

count_mismatch(a::AbstractArray, b::AbstractArray) = count(!=(0), a .!= b)

# ── correctness validations (GPU vs scalar reference) ────────────────────────

function validate_coverage(::Type{T}) where T
    Random.seed!(20260713)
    positions = random_positions(24, 10, T)
    ground_points, weights = ground_grid(5, 10, T)
    expected = coverage_reference(positions, ground_points, weights)
    device_positions = CuArray(positions)
    device_ground_points = CuArray(ground_points)
    device_weights = CuArray(weights)
    backend = get_backend(device_positions)
    cpu_backend_type = typeof(get_backend(Array{T}(undef, 0)))
    typeof(backend) == cpu_backend_type && error("CUDA input selected a CPU backend")

    actual = coverage_loss_gpu(
        device_positions,
        device_ground_points,
        device_weights,
    )
    tolerance = T === Float64 ? (rtol=1e-9, atol=1e-10) : (rtol=5e-4, atol=5e-5)
    isapprox(actual, expected; tolerance...) ||
        error("coverage parity failed for $T: actual=$actual expected=$expected")
    error_value = abs(actual - expected) / max(abs(expected), eps(T))
    println(
        "COVERAGE_PARITY type=$T status=PASS relative_error=$error_value backend=$(typeof(backend))",
    )
end

function validate_canonical_gsl(::Type{T}) where T
    radius = T(EARTH_RADIUS_KM)
    offset = T(500)
    positions = zeros(T, 4, 1, 3)
    positions[1, 1, :] .= (radius + offset, zero(T), zero(T))
    positions[2, 1, :] .= (radius, offset, zero(T))
    positions[3, 1, :] .= (radius + offset, offset, zero(T))
    positions[4, 1, :] .= (radius - offset, zero(T), zero(T))
    ground_ecef = reshape(T[radius, zero(T), zero(T)], 1, 3)
    ned_rotation = zeros(T, 1, 3, 3)
    ned_rotation[1, 1, 3] = one(T)
    ned_rotation[1, 2, 2] = one(T)
    ned_rotation[1, 3, 1] = -one(T)

    actual_device = evaluate_gsl_batch_gpu(
        CuArray(positions),
        CuArray(ground_ecef),
        CuArray(ned_rotation),
    )
    actual = map(Array, actual_device)
    expected_available = reshape(Bool[true, false, true, false], 4, 1, 1)
    expected_distances =
        reshape(T[offset, offset, sqrt(T(2)) * offset, offset], 4, 1, 1)
    expected_elevations = reshape(T[90, 0, 45, -90], 4, 1, 1)
    expected_delays =
        expected_distances ./ T(SPEED_OF_LIGHT_KM_S) .* T(1000)
    tolerance = T === Float64 ? (rtol=1e-12, atol=1e-12) : (rtol=1e-5, atol=1e-4)

    actual[1] == expected_available ||
        error("canonical GSL availability failed for $T")
    elementwise_isapprox(actual[2], expected_distances; tolerance...) ||
        error("canonical GSL distance failed for $T")
    elementwise_isapprox(actual[3], expected_elevations; tolerance...) ||
        error("canonical GSL elevation failed for $T")
    elementwise_isapprox(actual[4], expected_delays; tolerance...) ||
        error("canonical GSL delay failed for $T")
    println("GSL_CANONICAL type=$T status=PASS")
end

function validate_gsl(::Type{T}) where T
    Random.seed!(20260714)
    positions = random_positions(32, 12, T)
    ground_ecef, ned_rotation = station_geometry(8, T)
    expected = gsl_reference(positions, ground_ecef, ned_rotation)
    actual_device = evaluate_gsl_batch_gpu(
        CuArray(positions),
        CuArray(ground_ecef),
        CuArray(ned_rotation),
    )
    all(output -> output isa CuArray, actual_device) ||
        error("GSL outputs were not allocated on CUDA")
    actual = map(Array, actual_device)

    distance_tolerance =
        T === Float64 ? (rtol=1e-9, atol=1e-9) : (rtol=2e-5, atol=2e-3)
    elevation_tolerance =
        T === Float64 ? (rtol=1e-9, atol=1e-9) : (rtol=2e-5, atol=2e-3)
    delay_tolerance =
        T === Float64 ? (rtol=1e-9, atol=1e-10) : (rtol=2e-5, atol=2e-5)
    actual[1] == expected[1] || error("GSL availability parity failed for $T")
    elementwise_isapprox(actual[2], expected[2]; distance_tolerance...) ||
        error("GSL distance parity failed for $T")
    elementwise_isapprox(actual[3], expected[3]; elevation_tolerance...) ||
        error("GSL elevation parity failed for $T")
    elementwise_isapprox(actual[4], expected[4]; delay_tolerance...) ||
        error("GSL delay parity failed for $T")

    println(
        "GSL_PARITY type=$T status=PASS " *
        "distance_relative_error=$(relative_error(actual[2], expected[2])) " *
        "elevation_relative_error=$(relative_error(actual[3], expected[3])) " *
        "delay_relative_error=$(relative_error(actual[4], expected[4]))",
    )
end

function validate_isl(::Type{T}) where T
    positions, velocities = isl_scenario(48, 12, T; seed=20260717)
    pairs = make_pairs(48, 240)
    expected = isl_reference(positions, pairs; velocities=velocities)
    actual_device = evaluate_isl_batch_gpu(
        CuArray(positions),
        pairs;
        velocities=CuArray(velocities),
    )
    actual_device.available isa CuArray ||
        error("ISL outputs were not allocated on CUDA")
    actual = map(Array, values(actual_device))
    actual = (; zip(keys(actual_device), actual)...)

    distance_error = max_rel_error(actual.distance_km, expected.distance_km)
    delay_error = max_rel_error(actual.delay_ms, expected.delay_ms)
    elevation_error = max_rel_error(actual.elevation_deg, expected.elevation_deg)
    cos_psi_error = max_rel_error(actual.cos_psi, expected.cos_psi)
    duration_error = max_rel_error(actual.duration_s, expected.duration_s)
    available_mismatch = count_mismatch(actual.available, expected.available)
    los_mismatch = count_mismatch(actual.line_of_sight, expected.line_of_sight)
    total = length(expected.available)

    if T === Float64
        (available_mismatch == 0 && los_mismatch == 0) ||
            error("ISL Float64 boolean parity failed: available=$available_mismatch los=$los_mismatch")
        distance_error <= 1e-9 || error("ISL Float64 distance parity failed: $distance_error")
        delay_error <= 1e-9 || error("ISL Float64 delay parity failed: $delay_error")
        elevation_error <= 1e-8 || error("ISL Float64 elevation parity failed: $elevation_error")
        cos_psi_error <= 1e-8 || error("ISL Float64 azimuth parity failed: $cos_psi_error")
        duration_error <= 1e-6 || error("ISL Float64 duration parity failed: $duration_error")
    else
        (available_mismatch == 0 && los_mismatch == 0) ||
            error("ISL Float32 boolean parity failed: available=$available_mismatch los=$los_mismatch")
        distance_error <= 2e-4 || error("ISL Float32 distance parity failed: $distance_error")
        delay_error <= 2e-4 || error("ISL Float32 delay parity failed: $delay_error")
        elevation_error <= 2e-4 || error("ISL Float32 elevation parity failed: $elevation_error")
        cos_psi_error <= 2e-4 || error("ISL Float32 azimuth parity failed: $cos_psi_error")
        duration_error <= 2e-4 || error("ISL Float32 duration parity failed: $duration_error")
    end

    println(
        "ISL_PARITY type=$T status=PASS " *
        "available_mismatch=$available_mismatch/$total los_mismatch=$los_mismatch/$total " *
        "distance_relative_error=$distance_error delay_relative_error=$delay_error " *
        "elevation_relative_error=$elevation_error cos_psi_relative_error=$cos_psi_error " *
        "duration_relative_error=$duration_error",
    )
end

function validate_registered_compute_backend(::Type{T}) where T
    Random.seed!(20260716)
    positions = random_positions(32, 12, T)
    stations = station_tuples(8)
    register_kernel_compute_backend!(:cuda, CUDA.CUDABackend(); replace=true)
    selected = create_compute_backend(
        ComputeBackendSpec(:cuda; precision=T === Float64 ? "float64" : "float32"),
    )
    compute_backend_capabilities(selected).device == :gpu ||
        error("registered CUDA backend does not report a GPU device")

    ground_ecef, ned_rotation =
        SatelliteSimGPU._gsl_station_geometry(stations, T)
    expected = gsl_reference(
        positions,
        ground_ecef,
        ned_rotation;
        minimum_elevation=T(25.0),
        maximum_range=T(2000.0),
    )
    actual = evaluate_gsl_series(
        selected,
        positions,
        stations;
        gsl_min_elevation_deg=25.0,
        gsl_max_range_km=2000.0,
    )
    tolerance = T === Float64 ? (rtol=1e-9, atol=1e-9) : (rtol=2e-5, atol=2e-3)
    actual.available == expected[1] ||
        error("registered backend availability parity failed for $T")
    elementwise_isapprox(actual.distance_km, expected[2]; tolerance...) ||
        error("registered backend distance parity failed for $T")
    elementwise_isapprox(actual.elevation_deg, expected[3]; tolerance...) ||
        error("registered backend elevation parity failed for $T")
    elementwise_isapprox(actual.delay_ms, expected[4]; tolerance...) ||
        error("registered backend delay parity failed for $T")
    println(
        "REGISTERED_COMPUTE_BACKEND type=$T status=PASS backend=$(compute_backend_name(selected))",
    )
end

function validate_cuda_pipeline_and_adjoint()
    T = Float64
    elements = random_kepler_elements(12, T; seed=20260718)
    tspan = collect(T, 0:120:1200)
    host_eci = propagate_kepler_gpu(elements..., tspan; model=:j2)
    device_elements = map(CuArray, elements)
    device_tspan = CuArray(tspan)
    device_eci = propagate_kepler_gpu(device_elements..., device_tspan; model=:j2)
    device_eci isa CuArray || error("propagation output was not allocated on CUDA")
    isapprox(Array(device_eci), host_eci; rtol=1e-10, atol=1e-8) ||
        error("CUDA propagation parity failed")

    host_ecef = teme_to_pef_gpu(host_eci, tspan)
    device_ecef = teme_to_pef_gpu(device_eci, device_tspan)
    device_ecef isa CuArray || error("frame output was not allocated on CUDA")
    isapprox(Array(device_ecef), host_ecef; rtol=1e-10, atol=1e-8) ||
        error("CUDA TEME-to-PEF parity failed")

    Random.seed!(20260719)
    positions = random_positions(8, 4, T)
    ground_points, weights = ground_grid(4, 6, T)
    coverage_options = (
        min_el=T(10),
        τ_cov=T(5),
        dt=one(T),
        τ_revisit=one(T),
        λ=T(0.1),
    )
    host_loss, host_pullback = ChainRulesCore.rrule(
        coverage_loss_gpu,
        positions,
        ground_points,
        weights;
        coverage_options...,
    )
    _, host_gradient, _, _ = host_pullback(one(T))

    device_positions = CuArray(positions)
    device_ground_points = CuArray(ground_points)
    device_weights = CuArray(weights)
    device_loss, device_pullback = ChainRulesCore.rrule(
        coverage_loss_gpu,
        device_positions,
        device_ground_points,
        device_weights;
        coverage_options...,
    )
    _, device_gradient, _, _ = device_pullback(one(T))
    device_gradient isa CuArray || error("adjoint output was not allocated on CUDA")
    isapprox(device_loss, host_loss; rtol=1e-10, atol=1e-12) ||
        error("CUDA adjoint forward parity failed")
    all(isfinite, Array(device_gradient)) ||
        error("CUDA adjoint returned non-finite gradients")
    isapprox(Array(device_gradient), host_gradient; rtol=1e-8, atol=1e-8) ||
        error("CUDA adjoint gradient parity failed")

    saturated_positions = CuArray(reshape(T[7000, 0, 0], 1, 1, 3))
    saturated_ground = CuArray(reshape(T[EARTH_RADIUS_KM, 0, 0], 1, 3))
    saturated_weights = CuArray(T[1])
    _, saturated_pullback = ChainRulesCore.rrule(
        coverage_loss_gpu,
        saturated_positions,
        saturated_ground,
        saturated_weights;
        min_el=T(-90),
        τ_cov=T(1e-3),
        dt=one(T),
        τ_revisit=one(T),
        λ=T(0.1),
    )
    _, saturated_gradient, _, _ = saturated_pullback(one(T))
    saturated_gradient_host = Array(saturated_gradient)
    all(isfinite, saturated_gradient_host) ||
        error("saturated CUDA adjoint returned non-finite gradients")
    all(iszero, saturated_gradient_host) ||
        error("saturated CUDA adjoint returned non-zero gradients")

    println("CUDA_PIPELINE_ADJOINT status=PASS")
    return nothing
end

# ── timing ───────────────────────────────────────────────────────────────────

function best_elapsed(f, samples::Int; synchronize::Bool=false)
    times = Vector{Float64}(undef, samples)
    for sample_index in 1:samples
        synchronize && CUDA.synchronize()
        start_time = time_ns()
        f()
        synchronize && CUDA.synchronize()
        times[sample_index] = (time_ns() - start_time) / 1e9
    end
    return minimum(times)
end

const CPU_SAMPLES = 3
const GPU_SAMPLES = 20

# ── multi-scale benchmark suite (GPU CUDA vs CPU KernelAbstractions backend) ──

function bench_coverage_case(n_satellites::Int, n_times::Int, n_ground::Int, ::Type{T}) where T
    Random.seed!(1000 + n_satellites + n_times + n_ground)
    positions = random_positions(n_satellites, n_times, T)
    n_lat = max(1, floor(Int, sqrt(n_ground)))
    n_lon = cld(n_ground, n_lat)
    ground_points, weights = ground_grid(n_lat, n_lon, T)
    ground_points = ground_points[1:n_ground, :]
    weights = weights[1:n_ground]

    cpu_value = coverage_loss_gpu(positions, ground_points, weights)
    cpu_seconds =
        best_elapsed(() -> coverage_loss_gpu(positions, ground_points, weights), CPU_SAMPLES)

    device_positions = CuArray(positions)
    device_ground_points = CuArray(ground_points)
    device_weights = CuArray(weights)
    gpu_value = coverage_loss_gpu(device_positions, device_ground_points, device_weights)
    CUDA.synchronize()
    gpu_seconds = best_elapsed(
        () -> coverage_loss_gpu(device_positions, device_ground_points, device_weights),
        GPU_SAMPLES;
        synchronize=true,
    )

    e2e_call() = device_pipeline(
        (p, g, w) -> coverage_loss_gpu(p, g, w),
        CUDA.CUDABackend(),
        positions,
        ground_points,
        weights,
    )
    e2e_call()
    CUDA.synchronize()
    e2e_seconds = best_elapsed(e2e_call, GPU_SAMPLES; synchronize=true)

    relative = abs(gpu_value - cpu_value) / max(abs(cpu_value), eps(Float64))
    tolerance = T === Float64 ? 1e-8 : 2e-2
    parity = relative <= tolerance ? "PASS" : "WARN"
    units = float(n_satellites) * n_times * n_ground

    println(
        "BENCH op=coverage type=$T N=$n_satellites NT=$n_times G=$n_ground " *
        "units=$(round(Int, units)) " *
        "cpu_backend_s=$cpu_seconds gpu_compute_s=$gpu_seconds gpu_e2e_s=$e2e_seconds " *
        "speedup_compute=$(cpu_seconds / gpu_seconds) speedup_e2e=$(cpu_seconds / e2e_seconds) " *
        "gpu_throughput_eps=$(units / gpu_seconds) cpu_throughput_eps=$(units / cpu_seconds) " *
        "parity=$parity rel_err=$relative cpu_samples=$CPU_SAMPLES gpu_samples=$GPU_SAMPLES",
    )

    CUDA.unsafe_free!(device_positions)
    CUDA.unsafe_free!(device_ground_points)
    CUDA.unsafe_free!(device_weights)
    GC.gc()
    CUDA.reclaim()
    return nothing
end

function bench_gsl_case(n_satellites::Int, n_stations::Int, n_times::Int, ::Type{T}) where T
    Random.seed!(2000 + n_satellites + n_stations + n_times)
    positions = random_positions(n_satellites, n_times, T)
    ground_ecef, ned_rotation = station_geometry(n_stations, T)

    evaluate_gsl_batch_gpu(positions, ground_ecef, ned_rotation)
    cpu_seconds = best_elapsed(
        () -> evaluate_gsl_batch_gpu(positions, ground_ecef, ned_rotation),
        CPU_SAMPLES,
    )
    cpu_result = evaluate_gsl_batch_gpu(positions, ground_ecef, ned_rotation)

    device_positions = CuArray(positions)
    device_ground_ecef = CuArray(ground_ecef)
    device_ned_rotation = CuArray(ned_rotation)
    evaluate_gsl_batch_gpu(device_positions, device_ground_ecef, device_ned_rotation)
    CUDA.synchronize()
    gpu_seconds = best_elapsed(
        () -> evaluate_gsl_batch_gpu(
            device_positions,
            device_ground_ecef,
            device_ned_rotation,
        ),
        GPU_SAMPLES;
        synchronize=true,
    )

    e2e_call() = device_pipeline(
        (p, g, n) -> evaluate_gsl_batch_gpu(p, g, n),
        CUDA.CUDABackend(),
        positions,
        ground_ecef,
        ned_rotation,
    )
    e2e_call()
    CUDA.synchronize()
    e2e_seconds = best_elapsed(e2e_call, GPU_SAMPLES; synchronize=true)

    device_result =
        evaluate_gsl_batch_gpu(device_positions, device_ground_ecef, device_ned_rotation)
    CUDA.synchronize()
    gpu_host = map(Array, device_result)
    available_mismatch = count_mismatch(gpu_host[1], cpu_result[1])
    distance_error = max_rel_error(gpu_host[2], cpu_result[2])
    elevation_error = max_rel_error(gpu_host[3], cpu_result[3])
    delay_error = max_rel_error(gpu_host[4], cpu_result[4])
    tolerance = T === Float64 ? 1e-8 : 1e-3
    parity = (distance_error <= tolerance && delay_error <= tolerance) ? "PASS" : "WARN"
    units = float(n_satellites) * n_stations * n_times

    println(
        "BENCH op=gsl type=$T N=$n_satellites M=$n_stations NT=$n_times " *
        "units=$(round(Int, units)) " *
        "cpu_backend_s=$cpu_seconds gpu_compute_s=$gpu_seconds gpu_e2e_s=$e2e_seconds " *
        "speedup_compute=$(cpu_seconds / gpu_seconds) speedup_e2e=$(cpu_seconds / e2e_seconds) " *
        "gpu_throughput_eps=$(units / gpu_seconds) cpu_throughput_eps=$(units / cpu_seconds) " *
        "parity=$parity avail_mismatch=$available_mismatch " *
        "distance_rel_err=$distance_error elevation_rel_err=$elevation_error delay_rel_err=$delay_error " *
        "cpu_samples=$CPU_SAMPLES gpu_samples=$GPU_SAMPLES",
    )

    CUDA.unsafe_free!(device_positions)
    CUDA.unsafe_free!(device_ground_ecef)
    CUDA.unsafe_free!(device_ned_rotation)
    device_result = nothing
    gpu_host = nothing
    cpu_result = nothing
    GC.gc()
    CUDA.reclaim()
    return nothing
end

function bench_isl_case(n_satellites::Int, n_pairs::Int, n_times::Int, ::Type{T}) where T
    positions, velocities = isl_scenario(n_satellites, n_times, T; seed=3000 + n_satellites + n_times)
    pairs = make_pairs(n_satellites, n_pairs)
    actual_pairs = length(pairs)

    evaluate_isl_batch_gpu(positions, pairs; velocities=velocities)
    cpu_seconds = best_elapsed(
        () -> evaluate_isl_batch_gpu(positions, pairs; velocities=velocities),
        CPU_SAMPLES,
    )
    cpu_result = evaluate_isl_batch_gpu(positions, pairs; velocities=velocities)

    device_positions = CuArray(positions)
    device_velocities = CuArray(velocities)
    evaluate_isl_batch_gpu(device_positions, pairs; velocities=device_velocities)
    CUDA.synchronize()
    gpu_seconds = best_elapsed(
        () -> evaluate_isl_batch_gpu(device_positions, pairs; velocities=device_velocities),
        GPU_SAMPLES;
        synchronize=true,
    )

    e2e_call() = device_pipeline(
        (p, v) -> evaluate_isl_batch_gpu(p, pairs; velocities=v),
        CUDA.CUDABackend(),
        positions,
        velocities,
    )
    e2e_call()
    CUDA.synchronize()
    e2e_seconds = best_elapsed(e2e_call, GPU_SAMPLES; synchronize=true)

    device_result =
        evaluate_isl_batch_gpu(device_positions, pairs; velocities=device_velocities)
    CUDA.synchronize()
    available_mismatch = count_mismatch(Array(device_result.available), cpu_result.available)
    distance_error = max_rel_error(Array(device_result.distance_km), cpu_result.distance_km)
    elevation_error = max_rel_error(Array(device_result.elevation_deg), cpu_result.elevation_deg)
    duration_error = max_rel_error(Array(device_result.duration_s), cpu_result.duration_s)
    tolerance = T === Float64 ? 1e-8 : 1e-3
    parity = distance_error <= tolerance ? "PASS" : "WARN"
    units = float(actual_pairs) * n_times

    println(
        "BENCH op=isl type=$T N=$n_satellites P=$actual_pairs NT=$n_times " *
        "units=$(round(Int, units)) " *
        "cpu_backend_s=$cpu_seconds gpu_compute_s=$gpu_seconds gpu_e2e_s=$e2e_seconds " *
        "speedup_compute=$(cpu_seconds / gpu_seconds) speedup_e2e=$(cpu_seconds / e2e_seconds) " *
        "gpu_throughput_eps=$(units / gpu_seconds) cpu_throughput_eps=$(units / cpu_seconds) " *
        "parity=$parity avail_mismatch=$available_mismatch " *
        "distance_rel_err=$distance_error elevation_rel_err=$elevation_error duration_rel_err=$duration_error " *
        "cpu_samples=$CPU_SAMPLES gpu_samples=$GPU_SAMPLES",
    )

    CUDA.unsafe_free!(device_positions)
    CUDA.unsafe_free!(device_velocities)
    device_result = nothing
    cpu_result = nothing
    GC.gc()
    CUDA.reclaim()
    return nothing
end

# ── reduction benchmark: full-download+host-reduce vs device-aggregate ────────
# 真机瓶颈是下载 (N,M,NT)/(pairs,NT) 大数组。这里对比"只要摘要"调用方的两条端到端
# 路径（各含 H2D + 设备算 + D2H），量化设备端归约省下的传输与时间。

function bench_gsl_reduction_case(n_satellites::Int, n_stations::Int, n_times::Int, ::Type{T}) where T
    Random.seed!(4000 + n_satellites + n_stations + n_times)
    positions = random_positions(n_satellites, n_times, T)
    ground_ecef, ned_rotation = station_geometry(n_stations, T)

    # full-download：设备算完整 (N,M,NT)×4 → 全部下载 → host 归约得 (M,NT) 计数
    full_call() = device_pipeline(
        (p, g, n) -> evaluate_gsl_batch_gpu(p, g, n),
        CUDA.CUDABackend(), positions, ground_ecef, ned_rotation,
    )
    full_reduce() = begin
        host = full_call()
        Int32.(dropdims(sum(host[1]; dims=1); dims=1))
    end
    # device-aggregate：设备端归约核 → 只下载 (M,NT) 计数
    agg_call() = device_pipeline(
        (p, g, n) -> gsl_visible_counts_gpu(p, g, n),
        CUDA.CUDABackend(), positions, ground_ecef, ned_rotation,
    )

    parity = (full_reduce() == agg_call()) ? "PASS" : "FAIL"
    CUDA.synchronize()
    full_s = best_elapsed(full_reduce, GPU_SAMPLES; synchronize=true)
    agg_s = best_elapsed(agg_call, GPU_SAMPLES; synchronize=true)

    bytes_full = n_satellites * n_stations * n_times * (sizeof(Bool) + 3 * sizeof(T))
    bytes_agg = n_stations * n_times * sizeof(Int32)

    println(
        "BENCH op=gsl_reduction type=$T N=$n_satellites M=$n_stations NT=$n_times " *
        "full_e2e_s=$full_s agg_e2e_s=$agg_s speedup=$(full_s / agg_s) " *
        "download_bytes_full=$bytes_full download_bytes_agg=$bytes_agg " *
        "transfer_reduction=$(bytes_full / bytes_agg) parity=$parity " *
        "gpu_samples=$GPU_SAMPLES",
    )
    parity == "PASS" || error("GSL reduction parity failed for $T N=$n_satellites")
    GC.gc()
    CUDA.reclaim()
    return nothing
end

function bench_isl_reduction_case(n_satellites::Int, n_pairs::Int, n_times::Int, ::Type{T}) where T
    positions, velocities = isl_scenario(n_satellites, n_times, T; seed=5000 + n_satellites + n_times)
    pairs = make_pairs(n_satellites, n_pairs)
    actual_pairs = length(pairs)

    # full-download：设备算完整 (pairs,NT)×7 → 全部下载 → host 归约得 (NT,) 计数
    full_call() = device_pipeline(
        (p, v) -> evaluate_isl_batch_gpu(p, pairs; velocities=v),
        CUDA.CUDABackend(), positions, velocities,
    )
    full_reduce() = Int32.(vec(sum(full_call().available; dims=1)))
    # device-aggregate：设备端归约核 → 只下载 (NT,) 计数
    agg_call() = device_pipeline(
        (p, v) -> isl_available_counts_gpu(p, pairs; velocities=v),
        CUDA.CUDABackend(), positions, velocities,
    )

    parity = (full_reduce() == agg_call()) ? "PASS" : "FAIL"
    CUDA.synchronize()
    full_s = best_elapsed(full_reduce, GPU_SAMPLES; synchronize=true)
    agg_s = best_elapsed(agg_call, GPU_SAMPLES; synchronize=true)

    bytes_full = actual_pairs * n_times * (2 * sizeof(Bool) + 5 * sizeof(T))
    bytes_agg = n_times * sizeof(Int32)

    println(
        "BENCH op=isl_reduction type=$T N=$n_satellites P=$actual_pairs NT=$n_times " *
        "full_e2e_s=$full_s agg_e2e_s=$agg_s speedup=$(full_s / agg_s) " *
        "download_bytes_full=$bytes_full download_bytes_agg=$bytes_agg " *
        "transfer_reduction=$(bytes_full / bytes_agg) parity=$parity " *
        "gpu_samples=$GPU_SAMPLES",
    )
    parity == "PASS" || error("ISL reduction parity failed for $T N=$n_satellites")
    GC.gc()
    CUDA.reclaim()
    return nothing
end

function run_case(f, args...)
    try
        f(args...)
        return true
    catch err
        buffer = IOBuffer()
        showerror(buffer, err)
        message = replace(String(take!(buffer)), '\n' => " | ")
        println("BENCH_ERROR case=$(nameof(f)) args=$(args) message=$message")
        return false
    end
end

const COVERAGE_SCALES = (
    (66, 60, 500),
    (550, 90, 1000),
    (1584, 90, 1500),
    (1584, 240, 500),
)
const GSL_SCALES = (
    (66, 20, 60),
    (550, 40, 90),
    (1584, 64, 90),
    (1584, 100, 60),
)
const ISL_SCALES = (
    (66, 132, 60),
    (550, 1100, 90),
    (1584, 3168, 90),
    (1584, 6336, 90),
)
const GSL_REDUCTION_SCALES = (
    (550, 40, 90),
    (1584, 64, 90),
    (1584, 100, 90),
)
const ISL_REDUCTION_SCALES = (
    (550, 1100, 90),
    (1584, 3168, 90),
    (1584, 6336, 90),
)

function _run_typed_cases(label, scales, bench_fn)
    println("BENCH_SUITE_BEGIN op=$label")
    failed_cases = 0
    for T in (Float32, Float64)
        for args in scales
            run_case(bench_fn, args..., T) || (failed_cases += 1)
        end
    end
    println("BENCH_SUITE_END op=$label")
    failed_cases == 0 ||
        error("$failed_cases $label benchmark case(s) failed; see BENCH_ERROR lines")
    return nothing
end

run_bench_coverage() = _run_typed_cases("coverage", COVERAGE_SCALES, bench_coverage_case)
run_bench_gsl() = _run_typed_cases("gsl", GSL_SCALES, bench_gsl_case)
run_bench_isl() = _run_typed_cases("isl", ISL_SCALES, bench_isl_case)
run_bench_gsl_reduction() =
    _run_typed_cases("gsl_reduction", GSL_REDUCTION_SCALES, bench_gsl_reduction_case)
run_bench_isl_reduction() =
    _run_typed_cases("isl_reduction", ISL_REDUCTION_SCALES, bench_isl_reduction_case)

function run_benchmark_suite()
    run_bench_coverage()
    run_bench_gsl()
    run_bench_isl()
    run_bench_gsl_reduction()
    run_bench_isl_reduction()
    return nothing
end

# ── device-aggregate reductions vs full-download host reduce (CUDA) ───────────

function validate_reductions(::Type{T}) where T
    Random.seed!(20260720)
    positions = random_positions(48, 12, T)
    ground_ecef, ned_rotation = station_geometry(16, T)
    full = evaluate_gsl_batch_gpu(
        CuArray(positions),
        CuArray(ground_ecef),
        CuArray(ned_rotation);
        gsl_min_elevation_deg=T(25),
        gsl_max_range_km=T(2000),
    )
    counts = Array(
        gsl_visible_counts_gpu(
            CuArray(positions),
            CuArray(ground_ecef),
            CuArray(ned_rotation);
            gsl_min_elevation_deg=T(25),
            gsl_max_range_km=T(2000),
        ),
    )
    ratio = Array(
        gsl_station_visible_ratio_gpu(
            CuArray(positions),
            CuArray(ground_ecef),
            CuArray(ned_rotation);
            gsl_min_elevation_deg=T(25),
            gsl_max_range_km=T(2000),
        ),
    )
    available_host = Array(full[1])
    n_stations = size(ground_ecef, 1)
    n_times = size(positions, 2)
    expected_counts = Int32.(dropdims(sum(available_host; dims=1); dims=1))
    expected_ratio =
        T.(dropdims(sum(expected_counts .> 0; dims=2); dims=2)) ./ T(n_times)
    size(counts) == (n_stations, n_times) ||
        error("GSL visible-count shape mismatch for $T")
    counts == expected_counts || error("GSL visible-count reduction parity failed for $T")
    ratio == expected_ratio || error("GSL station-ratio reduction parity failed for $T")

    isl_positions, isl_velocities = isl_scenario(36, 10, T; seed=77)
    pairs = make_pairs(36, 72)
    full_isl = evaluate_isl_batch_gpu(
        CuArray(isl_positions),
        pairs;
        velocities=CuArray(isl_velocities),
    )
    isl_counts = Array(
        isl_available_counts_gpu(
            CuArray(isl_positions),
            pairs;
            velocities=CuArray(isl_velocities),
        ),
    )
    isl_ratio = Array(
        isl_pair_available_ratio_gpu(
            CuArray(isl_positions),
            pairs;
            velocities=CuArray(isl_velocities),
        ),
    )
    isl_degree = Array(
        isl_satellite_degree_gpu(
            CuArray(isl_positions),
            pairs;
            velocities=CuArray(isl_velocities),
        ),
    )
    isl_available_host = Array(full_isl.available)
    n_isl_times = size(isl_available_host, 2)
    expected_isl_counts = Int32.(vec(sum(isl_available_host; dims=1)))
    expected_isl_ratio = T.(vec(sum(isl_available_host; dims=2))) ./ T(n_isl_times)
    expected_degree = zeros(Int32, size(isl_positions, 1), n_isl_times)
    for (pair_index, (i, j)) in enumerate(pairs), time_index in 1:n_isl_times
        if isl_available_host[pair_index, time_index]
            expected_degree[i, time_index] += Int32(1)
            expected_degree[j, time_index] += Int32(1)
        end
    end
    isl_counts == expected_isl_counts ||
        error("ISL available-count reduction parity failed for $T")
    isl_ratio == expected_isl_ratio ||
        error("ISL pair-ratio reduction parity failed for $T")
    isl_degree == expected_degree ||
        error("ISL degree reduction parity failed for $T")

    println("REDUCTIONS_PARITY type=$T status=PASS")
    return nothing
end

# ── near-Earth SGP4 CUDA parity vs SatelliteToolbox ───────────────────────────

function _random_sgp4_elements(n_sat; seed, a_range, e_range)
    Random.seed!(seed)
    mu = 398600.5
    n0 = Vector{Float64}(undef, n_sat)
    e0 = Vector{Float64}(undef, n_sat)
    i0 = Vector{Float64}(undef, n_sat)
    raan = Vector{Float64}(undef, n_sat)
    argp = Vector{Float64}(undef, n_sat)
    M0 = Vector{Float64}(undef, n_sat)
    bstar = Vector{Float64}(undef, n_sat)
    for s in 1:n_sat
        a = a_range[1] + (a_range[2] - a_range[1]) * rand()
        n0[s] = sqrt(mu / a^3) * 60
        e0[s] = e_range[1] + (e_range[2] - e_range[1]) * rand()
        i0[s] = deg2rad(20.0 + 130.0 * rand())
        raan[s] = deg2rad(360.0 * rand())
        argp[s] = deg2rad(360.0 * rand())
        M0[s] = deg2rad(360.0 * rand())
        bstar[s] = 1e-4 * randn()
    end
    return n0, e0, i0, raan, argp, M0, bstar
end

function _sgp4_reference_series(n0, e0, i0, raan, argp, M0, bstar, tspan)
    n_sat = length(n0)
    n_times = length(tspan)
    positions = Array{Float64}(undef, n_sat, n_times, 3)
    velocities = Array{Float64}(undef, n_sat, n_times, 3)
    for s in 1:n_sat
        sgp4d = sgp4_init(
            2.451545e6,
            n0[s], e0[s], i0[s], raan[s], argp[s], M0[s], bstar[s];
            sgp4c=sgp4c_wgs84,
        )
        for (time_index, t) in enumerate(tspan)
            r, v = sgp4!(sgp4d, t)
            positions[s, time_index, :] .= r
            velocities[s, time_index, :] .= v
        end
    end
    return positions, velocities
end

function validate_sgp4_cuda()
    for (label, seed, a_range, e_range, want_algo) in (
        ("sgp4", 41, (6750.0, 7200.0), (0.001, 0.02), Int32(1)),
        ("sgp4_lowper", 42, (6560.0, 6605.0), (0.0005, 0.0030), Int32(0)),
    )
        n0, e0, i0, raan, argp, M0, bstar =
            _random_sgp4_elements(24; seed=seed, a_range=a_range, e_range=e_range)
        tspan = collect(0.0:10.0:120.0)
        gold_pos, gold_vel =
            _sgp4_reference_series(n0, e0, i0, raan, argp, M0, bstar, tspan)
        el = sgp4_init_host(n0, e0, i0, raan, argp, M0, bstar)
        want_algo in el.algo || error("SGP4 branch $label not selected: algos=$(el.algo)")

        el_d = to_device(CUDA.CUDABackend(), el)
        tspan_d = CuArray(tspan)
        pos_d, vel_d = sgp4_propagate_gpu(el_d, tspan_d; velocities=true)
        pos_d isa CuArray || error("SGP4 CUDA positions were not device-resident")
        vel_d isa CuArray || error("SGP4 CUDA velocities were not device-resident")
        pos = Array(pos_d)
        vel = Array(vel_d)
        pos_err = maximum(abs.(pos .- gold_pos))
        vel_err = maximum(abs.(vel .- gold_vel))
        pos_err < 1e-6 || error("SGP4 CUDA position parity failed for $label: $pos_err")
        vel_err < 1e-9 || error("SGP4 CUDA velocity parity failed for $label: $vel_err")
        println(
            "SGP4_PARITY branch=$label status=PASS max_pos_err_km=$pos_err max_vel_err_km_s=$vel_err",
        )
    end

    # deep-space rejection + device-resident SGP4→ISL
    mu = 398600.5
    try
        sgp4_init_host(
            [sqrt(mu / 20000.0^3) * 60], [0.01], [deg2rad(55.0)], [0.0], [0.0], [0.0], [0.0],
        )
        error("deep-space SGP4 should have thrown")
    catch err
        err isa ArgumentError || rethrow()
    end

    n0, e0, i0, raan, argp, M0, bstar =
        _random_sgp4_elements(12; seed=9, a_range=(6750.0, 7200.0), e_range=(0.001, 0.02))
    tspan = collect(0.0:30.0:180.0)
    pairs = [(i, i + 1) for i in 1:11]
    el = sgp4_init_host(n0, e0, i0, raan, argp, M0, bstar)
    host_pos, host_vel = sgp4_propagate_gpu(el, tspan; velocities=true)
    host_isl = evaluate_isl_batch_gpu(host_pos, pairs; velocities=host_vel)
    out = device_pipeline(CUDA.CUDABackend(), el, tspan) do e, ts
        p, v = sgp4_propagate_gpu(e, ts; velocities=true)
        evaluate_isl_batch_gpu(p, pairs; velocities=v)
    end
    out.available == host_isl.available ||
        error("SGP4→ISL CUDA residency availability mismatch")
    isapprox(out.distance_km, host_isl.distance_km; rtol=1e-12, atol=1e-12) ||
        error("SGP4→ISL CUDA residency distance mismatch")
    println("SGP4_CUDA status=PASS")
    return nothing
end

function print_gpu_info()
    device = CUDA.device()
    fields = ["GPU_INFO device=$(CUDA.name(device))"]
    try
        push!(fields, "total_mem_gib=$(round(CUDA.totalmem(device) / 2^30; digits=2))")
    catch
    end
    try
        capability = CUDA.capability(device)
        push!(fields, "compute_capability=$(capability.major).$(capability.minor)")
    catch
    end
    try
        push!(fields, "driver=$(CUDA.driver_version())")
    catch
    end
    try
        push!(fields, "cuda_runtime=$(CUDA.runtime_version())")
    catch
    end
    push!(fields, "julia=$VERSION")
    push!(fields, "cuda_jl=$(pkgversion(CUDA))")
    push!(fields, "kernel_abstractions=$(pkgversion(KernelAbstractions))")
    push!(fields, "julia_threads=$(Threads.nthreads())")
    push!(fields, "cpu_threads_visible=$(Sys.CPU_THREADS)")
    try
        push!(fields, "cpu_model=$(replace(Sys.cpu_info()[1].model, ' ' => '_'))")
    catch
    end
    println(join(fields, " "))
    return nothing
end

const SUITE_HANDLERS = Dict{String,Function}(
    "smoke_info" => () -> (print_gpu_info(); nothing),
    "coverage_f64" => () -> validate_coverage(Float64),
    "coverage_f32" => () -> validate_coverage(Float32),
    "gsl_canonical_f64" => () -> validate_canonical_gsl(Float64),
    "gsl_canonical_f32" => () -> validate_canonical_gsl(Float32),
    "gsl_f64" => () -> validate_gsl(Float64),
    "gsl_f32" => () -> validate_gsl(Float32),
    "isl_f64" => () -> validate_isl(Float64),
    "isl_f32" => () -> validate_isl(Float32),
    "registered_f64" => () -> validate_registered_compute_backend(Float64),
    "registered_f32" => () -> validate_registered_compute_backend(Float32),
    "pipeline_adjoint" => validate_cuda_pipeline_and_adjoint,
    "reductions_f64" => () -> validate_reductions(Float64),
    "reductions_f32" => () -> validate_reductions(Float32),
    "sgp4_cuda" => validate_sgp4_cuda,
    "bench_coverage" => run_bench_coverage,
    "bench_gsl" => run_bench_gsl,
    "bench_isl" => run_bench_isl,
    "bench_gsl_reduction" => run_bench_gsl_reduction,
    "bench_isl_reduction" => run_bench_isl_reduction,
    "bench_all" => run_benchmark_suite,
    "full" => function ()
        validate_coverage(Float64)
        validate_coverage(Float32)
        validate_canonical_gsl(Float64)
        validate_canonical_gsl(Float32)
        validate_gsl(Float64)
        validate_gsl(Float32)
        validate_isl(Float64)
        validate_isl(Float32)
        validate_registered_compute_backend(Float64)
        validate_registered_compute_backend(Float32)
        validate_cuda_pipeline_and_adjoint()
        validate_reductions(Float64)
        validate_reductions(Float32)
        validate_sgp4_cuda()
        run_benchmark_suite()
        return nothing
    end,
)

function main()
    VERSION >= v"1.12" || error("Julia 1.12 or newer is required, found $VERSION")
    CUDA.functional() || error("CUDA is not functional")
    pkgversion(CUDA) == EXPECTED_CUDA_JL_VERSION ||
        error("expected CUDA.jl $EXPECTED_CUDA_JL_VERSION, found $(pkgversion(CUDA))")
    CUDA.allowscalar(false)

    suite = length(ARGS) >= 1 ? String(ARGS[1]) : "full"
    handler = get(SUITE_HANDLERS, suite, nothing)
    handler === nothing && error(
        "unknown suite=$suite; known=$(join(sort!(collect(keys(SUITE_HANDLERS))), ","))",
    )

    println("SUITE_BEGIN name=$suite")
    print_gpu_info()
    handler()
    println("SUITE_END name=$suite status=PASS")
    println("MODAL_GPU_VALIDATION status=PASS suite=$suite")
end

main()

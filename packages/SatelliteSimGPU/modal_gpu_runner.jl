using Pkg
# Ensure the pinned manifest deps are present in the container depot before load.
# No-op when already instantiated; guarded so a working image is never broken.
try
    Pkg.instantiate()
catch instantiate_error
    @warn "Pkg.instantiate failed; attempting to load anyway" exception = instantiate_error
end

using CUDA
using KernelAbstractions
using Random
using SatelliteSimBackends
using SatelliteSimGPU

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
        elevation_error <= 1e-8 || error("ISL Float64 elevation parity failed: $elevation_error")
        duration_error <= 1e-6 || error("ISL Float64 duration parity failed: $duration_error")
    else
        distance_error <= 2e-4 || error("ISL Float32 distance parity failed: $distance_error")
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

function run_case(f, args...)
    try
        f(args...)
    catch err
        buffer = IOBuffer()
        showerror(buffer, err)
        message = replace(String(take!(buffer)), '\n' => " | ")
        println("BENCH_ERROR case=$(nameof(f)) args=$(args) message=$message")
    end
    return nothing
end

function run_benchmark_suite()
    println("BENCH_SUITE_BEGIN")

    coverage_scales = (
        (66, 60, 500),
        (550, 90, 1000),
        (1584, 90, 1500),
        (1584, 240, 500),
    )
    gsl_scales = (
        (66, 20, 60),
        (550, 40, 90),
        (1584, 64, 90),
        (1584, 100, 60),
    )
    isl_scales = (
        (66, 132, 60),
        (550, 1100, 90),
        (1584, 3168, 90),
        (1584, 6336, 90),
    )

    for T in (Float32, Float64)
        for (n_satellites, n_times, n_ground) in coverage_scales
            run_case(bench_coverage_case, n_satellites, n_times, n_ground, T)
        end
        for (n_satellites, n_stations, n_times) in gsl_scales
            run_case(bench_gsl_case, n_satellites, n_stations, n_times, T)
        end
        for (n_satellites, n_pairs, n_times) in isl_scales
            run_case(bench_isl_case, n_satellites, n_pairs, n_times, T)
        end
    end

    println("BENCH_SUITE_END")
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

function main()
    VERSION >= v"1.12" || error("Julia 1.12 or newer is required, found $VERSION")
    CUDA.functional() || error("CUDA is not functional")
    pkgversion(CUDA) == EXPECTED_CUDA_JL_VERSION ||
        error("expected CUDA.jl $EXPECTED_CUDA_JL_VERSION, found $(pkgversion(CUDA))")
    CUDA.allowscalar(false)
    print_gpu_info()
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
    run_benchmark_suite()
    println("MODAL_GPU_VALIDATION status=PASS")
end

main()

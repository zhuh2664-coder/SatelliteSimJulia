using Printf
using Random
using KernelAbstractions
using SatelliteSimGPU

const SPEED_OF_LIGHT_KM_S = 299_792.458

function random_positions(n_satellites, n_times, T)
    positions = Array{T}(undef, n_satellites, n_times, 3)
    for satellite_index in 1:n_satellites, time_index in 1:n_times
        direction = randn(T, 3)
        direction ./= sqrt(sum(abs2, direction))
        positions[satellite_index, time_index, :] .=
            T(6900.0 + 100.0 * rand())
        positions[satellite_index, time_index, :] .*= direction
    end
    return positions
end

function random_stations(n_stations)
    stations = Vector{NTuple{3,Float64}}(undef, n_stations)
    for station_index in 1:n_stations
        lat = -70.0 + 140.0 * (station_index - 1) / max(n_stations - 1, 1)
        lon = mod(37.0 * station_index + 13.0, 360.0) - 180.0
        alt = 0.2 + 1.5 * mod(station_index, 5) / 4
        stations[station_index] = (lat, lon, alt)
    end
    return stations
end

function scalar_gsl_batch(positions, ground_ecef, ned_rotation)
    n_satellites, n_times, _ = size(positions)
    n_stations = size(ground_ecef, 1)
    available = Array{Bool}(undef, n_satellites, n_stations, n_times)
    distances = Array{Float64}(undef, n_satellites, n_stations, n_times)
    elevations = Array{Float64}(undef, n_satellites, n_stations, n_times)
    delays = Array{Float64}(undef, n_satellites, n_stations, n_times)

    for satellite_index in 1:n_satellites,
        station_index in 1:n_stations,
        time_index in 1:n_times
        delta = ntuple(
            component -> positions[satellite_index, time_index, component] -
                         ground_ecef[station_index, component],
            3,
        )
        north = sum(
            ned_rotation[station_index, 1, component] * delta[component]
            for component in 1:3
        )
        east = sum(
            ned_rotation[station_index, 2, component] * delta[component]
            for component in 1:3
        )
        down = sum(
            ned_rotation[station_index, 3, component] * delta[component]
            for component in 1:3
        )
        distance = sqrt(sum(abs2, delta))
        local_range = sqrt(north^2 + east^2 + down^2)
        elevation = local_range == 0 ? 90.0 :
                    rad2deg(π / 2 - acos(clamp(-down / local_range, -1.0, 1.0)))
        available[satellite_index, station_index, time_index] =
            distance <= 2000.0 && elevation >= 25.0
        distances[satellite_index, station_index, time_index] = distance
        elevations[satellite_index, station_index, time_index] = elevation
        delays[satellite_index, station_index, time_index] =
            distance / SPEED_OF_LIGHT_KM_S * 1000
    end

    return available, distances, elevations, delays
end

function parse_args(args)
    length(args) == 3 || error("usage: julia --project=. bench_gsl.jl N M NT")
    return parse.(Int, args)
end

n_satellites, n_stations, n_times = parse_args(ARGS)
all(>(0), (n_satellites, n_stations, n_times)) ||
    error("N, M, and NT must be positive")
Random.seed!(1234)
positions = random_positions(n_satellites, n_times, Float64)
stations = random_stations(n_stations)
ground_ecef, ned_rotation =
    SatelliteSimGPU._gsl_station_geometry(stations, Float64)

reference = scalar_gsl_batch(positions, ground_ecef, ned_rotation)
candidate = evaluate_gsl_batch_gpu(positions, ground_ecef, ned_rotation)
GC.gc()

reference_time = @elapsed reference =
    scalar_gsl_batch(positions, ground_ecef, ned_rotation)
kernel_time = @elapsed candidate = evaluate_gsl_batch_gpu(
    positions,
    ground_ecef,
    ned_rotation,
)
backend = get_backend(positions)

distance_error = maximum(
    abs.(candidate[2] .- reference[2]) ./ max.(abs.(reference[2]), eps(Float64)),
)
elevation_error = maximum(
    abs.(candidate[3] .- reference[3]) ./ max.(abs.(reference[3]), eps(Float64)),
)
delay_error = maximum(
    abs.(candidate[4] .- reference[4]) ./ max.(abs.(reference[4]), eps(Float64)),
)

@printf("N=%d M=%d NT=%d\n", n_satellites, n_stations, n_times)
@printf("%-20s %12s\n", "implementation", "seconds")
@printf("%-20s %12.6f\n", "cpu_reference", reference_time)
@printf("%-20s %12.6f\n", "ka_cpu_kernel", kernel_time)
@printf("reference_over_ka_cpu=%.6f\n", reference_time / kernel_time)
@printf("backend=%s device=cpu\n", string(typeof(backend)))
@printf("distance_relative_error=%.6e\n", distance_error)
@printf("elevation_relative_error=%.6e\n", elevation_error)
@printf("delay_relative_error=%.6e\n", delay_error)
@printf("available_equal=%s\n", string(candidate[1] == reference[1]))

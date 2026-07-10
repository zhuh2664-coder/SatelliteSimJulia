using Printf
using Random
using SatelliteToolbox
using SatelliteSimGPU

const GOLDEN_DIR = joinpath(@__DIR__, "golden")
include(joinpath(GOLDEN_DIR, "golden_gsl_reference.jl"))

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

function gsl_station_geometry(stations)
    n_stations = length(stations)
    ground_ecef = Matrix{Float64}(undef, n_stations, 3)
    ned_rotation = Array{Float64}(undef, n_stations, 3, 3)

    for (station_index, (lat, lon, alt)) in enumerate(stations)
        lat_rad = deg2rad(lat)
        lon_rad = deg2rad(lon)
        gs_m = SatelliteToolbox.geodetic_to_ecef(lat_rad, lon_rad, alt * 1000)
        for component in 1:3
            ground_ecef[station_index, component] = gs_m[component] / 1000
        end

        for column in 1:3
            delta_m = zeros(Float64, 3)
            delta_m[column] = 1.0
            ned_m = SatelliteToolbox.ecef_to_ned(
                gs_m .+ delta_m,
                lat_rad,
                lon_rad,
                alt * 1000;
                translate=true,
            )
            for row in 1:3
                ned_rotation[station_index, row, column] = ned_m[row]
            end
        end
    end

    return ground_ecef, ned_rotation
end

function golden_gsl_batch(positions, stations)
    n_satellites, n_times, _ = size(positions)
    n_stations = length(stations)
    available = Array{Bool}(undef, n_satellites, n_stations, n_times)
    distances = Array{Float64}(undef, n_satellites, n_stations, n_times)
    elevations = Array{Float64}(undef, n_satellites, n_stations, n_times)
    delays = Array{Float64}(undef, n_satellites, n_stations, n_times)

    for time_index in 1:n_times
        pos_matrix = @view positions[:, time_index, :]
        avail_t, dist_t, elev_t, delay_t =
            GoldenGSLReference.evaluate_gsl_batch(pos_matrix, stations)
        available[:, :, time_index] .= avail_t
        distances[:, :, time_index] .= dist_t
        elevations[:, :, time_index] .= elev_t
        delays[:, :, time_index] .= delay_t
    end

    return available, distances, elevations, delays
end

function parse_args(args)
    length(args) == 3 || error("usage: julia --project=. bench_gsl.jl N M NT")
    return parse.(Int, args)
end

n_satellites, n_stations, n_times = parse_args(ARGS)
Random.seed!(1234)
positions = random_positions(n_satellites, n_times, Float64)
stations = random_stations(n_stations)
ground_ecef, ned_rotation = gsl_station_geometry(stations)

reference_time = @elapsed reference = golden_gsl_batch(positions, stations)
candidate = evaluate_gsl_batch_gpu(positions, ground_ecef, ned_rotation)
gpu_time = @elapsed candidate = evaluate_gsl_batch_gpu(
    positions,
    ground_ecef,
    ned_rotation,
)

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
@printf("%-20s %12.6f\n", "evaluate_gsl_batch_gpu", gpu_time)
@printf("speedup=%.6f\n", reference_time / gpu_time)
@printf("distance_relative_error=%.6e\n", distance_error)
@printf("elevation_relative_error=%.6e\n", elevation_error)
@printf("delay_relative_error=%.6e\n", delay_error)
@printf("available_equal=%s\n", string(candidate[1] == reference[1]))

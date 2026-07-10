using Test
using Random
using KernelAbstractions
using SatelliteToolbox
using SatelliteSimGPU

const GOLDEN_DIR = joinpath(@__DIR__, "..", "golden")
include(joinpath(GOLDEN_DIR, "golden_reference.jl"))

function random_ground_grid(n_lat, n_lon, T)
    lat_bounds = (-70.0, 70.0)
    lats = range(deg2rad(lat_bounds[1]), deg2rad(lat_bounds[2]); length=n_lat)
    lons = range(deg2rad(-180.0), deg2rad(180.0); length=n_lon + 1)[1:end-1]
    points = Matrix{T}(undef, n_lat * n_lon, 3)
    weights = Vector{T}(undef, n_lat * n_lon)
    index = 1
    for φ in lats, λ in lons
        cφ = cos(φ)
        points[index, 1] = T(6378.137 * cφ * cos(λ))
        points[index, 2] = T(6378.137 * cφ * sin(λ))
        points[index, 3] = T(6378.137 * sin(φ))
        weights[index] = T(cφ)
        index += 1
    end
    return points, weights
end

function random_positions(n_sat, n_times, T)
    positions = Array{T}(undef, n_sat, n_times, 3)
    for sat in 1:n_sat, time_index in 1:n_times
        direction = randn(T, 3)
        direction ./= sqrt(sum(abs2, direction))
        radius = T(6900.0 + 100.0 * rand())
        positions[sat, time_index, :] .= radius .* direction
    end
    return positions
end

@testset "coverage_loss_gpu CPU parity" begin
    backend = get_backend(Array{Float64}(undef, 0))
    for (n_sat, n_times, n_lat, n_lon) in (
        (24, 10, 5, 10),
        (66, 30, 10, 20),
        (132, 60, 20, 25),
    )
        Random.seed!(n_sat + n_times + n_lat + n_lon)
        positions = random_positions(n_sat, n_times, Float64)
        ground_pts, weights = random_ground_grid(n_lat, n_lon, Float64)

        reference = GoldenReference.coverage_loss(
            positions,
            ground_pts,
            weights;
            min_el=10.0,
            τ_cov=5.0,
            dt=1.0,
            τ_revisit=1.0,
            λ=0.1,
        )
        candidate = coverage_loss_gpu(
            positions,
            ground_pts,
            weights;
            min_el=10.0,
            τ_cov=5.0,
            dt=1.0,
            τ_revisit=1.0,
            λ=0.1,
        )

        @test isapprox(candidate, reference; rtol=1e-10, atol=1e-12)
        @info "coverage parity" n_sat n_times n_ground=length(weights) reference candidate relative_error=abs(candidate - reference) / max(abs(reference), eps())
    end
end

@testset "coverage_loss_gpu validation" begin
    positions = zeros(Float64, 2, 3, 3)
    ground_pts = zeros(Float64, 4, 3)
    weights = ones(Float64, 4)
    @test_throws ArgumentError coverage_loss_gpu(
        positions[:, :, 1:2], ground_pts, weights,
    )
    @test_throws MethodError coverage_loss_gpu(
        positions, ground_pts, ones(Float32, 4),
    )
end

include(joinpath(GOLDEN_DIR, "golden_gsl_reference.jl"))

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

function random_gsl_stations(n_stations)
    stations = Vector{NTuple{3,Float64}}(undef, n_stations)
    for station_index in 1:n_stations
        lat = -70.0 + 140.0 * (station_index - 1) / max(n_stations - 1, 1)
        lon = mod(37.0 * station_index + 13.0, 360.0) - 180.0
        alt = 0.2 + 1.5 * mod(station_index, 5) / 4
        stations[station_index] = (lat, lon, alt)
    end
    return stations
end

@testset "evaluate_gsl_batch_gpu CPU parity" begin
    for (n_satellites, n_stations, n_times) in (
        (66, 10, 30),
        (132, 20, 60),
    )
        Random.seed!(n_satellites + n_stations + n_times)
        positions = random_positions(n_satellites, n_times, Float64)
        stations = random_gsl_stations(n_stations)
        ground_ecef, ned_rotation = gsl_station_geometry(stations)

        reference = golden_gsl_batch(positions, stations)
        candidate = evaluate_gsl_batch_gpu(
            positions,
            ground_ecef,
            ned_rotation;
            gsl_min_elevation_deg=25.0,
            gsl_max_range_km=2000.0,
        )

        @test candidate[1] == reference[1]
        @test isapprox(candidate[2], reference[2]; rtol=1e-10, atol=1e-10)
        @test isapprox(candidate[3], reference[3]; rtol=1e-10, atol=1e-10)
        @test isapprox(candidate[4], reference[4]; rtol=1e-10, atol=1e-10)

        for (label, actual, expected) in zip(
            ("distance", "elevation", "delay"),
            candidate[2:4],
            reference[2:4],
        )
            relative_error = maximum(
                abs.(actual .- expected) ./ max.(abs.(expected), eps(Float64)),
            )
            @info "GSL parity" n_satellites n_stations n_times label relative_error
        end
        @info "GSL availability parity" n_satellites n_stations n_times equal=(
            candidate[1] == reference[1]
        )

        if n_satellites == 66
            positions32 = Float32.(positions)
            ground_ecef32 = Float32.(ground_ecef)
            ned_rotation32 = Float32.(ned_rotation)
            candidate32 = evaluate_gsl_batch_gpu(
                positions32,
                ground_ecef32,
                ned_rotation32;
                gsl_min_elevation_deg=Float32(25.0),
                gsl_max_range_km=Float32(2000.0),
            )
            @test size(candidate32[1]) == (n_satellites, n_stations, n_times)
            @test candidate32[1] == reference[1]
            @test isapprox(
                candidate32[2],
                reference[2];
                rtol=1e-5,
                atol=1e-3,
            )
            @test isapprox(
                candidate32[3],
                reference[3];
                rtol=1e-5,
                atol=1e-3,
            )
            @test isapprox(
                candidate32[4],
                reference[4];
                rtol=1e-5,
                atol=1e-5,
            )
        end
    end
end

@testset "evaluate_gsl_batch_gpu validation" begin
    positions = zeros(Float64, 2, 3, 3)
    ground_ecef = zeros(Float64, 4, 3)
    ned_rotation = zeros(Float64, 4, 3, 3)
    @test_throws ArgumentError evaluate_gsl_batch_gpu(
        positions[:, :, 1:2], ground_ecef, ned_rotation,
    )
    @test_throws ArgumentError evaluate_gsl_batch_gpu(
        positions, ground_ecef, zeros(Float64, 4, 2, 3),
    )
end

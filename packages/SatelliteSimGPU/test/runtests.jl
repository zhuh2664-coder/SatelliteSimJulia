using Test
using Random
using LinearAlgebra
using KernelAbstractions
using ChainRulesCore
using SatelliteToolbox
using SatelliteSimBackends
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

@testset "Kernel compute backend GSL contract" begin
    Random.seed!(20260716)
    positions = random_positions(24, 8, Float64)
    stations = random_gsl_stations(6)
    expected = golden_gsl_batch(positions, stations)
    backend = KernelComputeBackend(CPU(); precision=Float64)
    actual = evaluate_gsl_series(
        backend,
        positions,
        stations;
        gsl_min_elevation_deg=25.0,
        gsl_max_range_km=2000.0,
    )

    @test actual.available == expected[1]
    @test isapprox(actual.distance_km, expected[2]; rtol=1e-10, atol=1e-10)
    @test isapprox(actual.elevation_deg, expected[3]; rtol=1e-10, atol=1e-10)
    @test isapprox(actual.delay_ms, expected[4]; rtol=1e-10, atol=1e-10)
    @test compute_backend_capabilities(backend).operations == (:gsl_series, :isl_series)
    @test compute_backend_capabilities(backend).device == :cpu
    @test compute_backend_fingerprint(backend).implementation_module ==
          "SatelliteSimGPU"
    @test compute_backend_cache_token(backend) !== nothing
    backend_source_files = compute_backend_source_files(backend)
    @test all(isfile, backend_source_files)
    @test any(endswith("adjoint.jl"), backend_source_files)
    @test any(endswith("isl.jl"), backend_source_files)
    @test compute_backend_capabilities(KernelComputeBackend(CPU())).precision ===
          Float64
    @test_throws ArgumentError register_kernel_compute_backend!(:not_gpu, CPU())
    @test SatelliteSimGPU._compute_precision((;)) === Float64
    @test SatelliteSimGPU._compute_precision((precision="float64",)) === Float64
    @test_throws ArgumentError SatelliteSimGPU._compute_precision(
        (precisionn="float64",),
    )

    empty_result = evaluate_gsl_series(
        backend,
        positions,
        NTuple{3,Float64}[];
        gsl_min_elevation_deg=25.0,
        gsl_max_range_km=2000.0,
    )
    @test size(empty_result.available) == (24, 0, 8)
end

include(joinpath(GOLDEN_DIR, "golden_isl_reference.jl"))

function random_isl_scenario(n_sat, n_times, ::Type{T}; seed=0) where {T}
    Random.seed!(seed)
    positions = Array{T}(undef, n_sat, n_times, 3)
    velocities = Array{T}(undef, n_sat, n_times, 3)
    for sat in 1:n_sat, time_index in 1:n_times
        dir = randn(T, 3)
        dir ./= sqrt(sum(abs2, dir))
        radius = T(6871.0 + 80.0 * rand())
        positions[sat, time_index, :] .= radius .* dir
        vdir = randn(T, 3)
        vdir ./= sqrt(sum(abs2, vdir))
        velocities[sat, time_index, :] .= T(7.6) .* vdir
    end
    return positions, velocities
end

@testset "evaluate_isl_batch_gpu CPU parity" begin
    for (n_sat, n_times) in ((12, 5), (30, 8))
        positions, velocities =
            random_isl_scenario(n_sat, n_times, Float64; seed=n_sat + n_times)
        pairs = Tuple{Int,Int}[]
        for i in 1:n_sat, j in (i + 1):n_sat
            push!(pairs, (i, j))
        end

        # 位置-only 路径（距离 + LOS + 距离约束）
        ref0 = GoldenISLReference.evaluate_isl_series(positions, pairs)
        cand0 = evaluate_isl_batch_gpu(positions, pairs)
        @test cand0.available == ref0.available
        @test cand0.line_of_sight == ref0.line_of_sight
        @test isapprox(cand0.distance_km, ref0.distance_km; rtol=1e-9, atol=1e-9)
        @test isapprox(cand0.delay_ms, ref0.delay_ms; rtol=1e-9, atol=1e-9)

        # 带速度路径（RTN 仰角 / 方位 / 持续时长）
        ref1 = GoldenISLReference.evaluate_isl_series(
            positions, pairs; velocities=velocities,
        )
        cand1 = evaluate_isl_batch_gpu(positions, pairs; velocities=velocities)
        @test cand1.available == ref1.available
        @test isapprox(cand1.distance_km, ref1.distance_km; rtol=1e-9, atol=1e-9)
        @test isapprox(cand1.elevation_deg, ref1.elevation_deg; rtol=1e-8, atol=1e-8)
        @test isapprox(cand1.cos_psi, ref1.cos_psi; rtol=1e-8, atol=1e-8)
        @test isapprox(cand1.duration_s, ref1.duration_s; rtol=1e-6, atol=1e-6)
        @info "ISL parity" n_sat n_times n_pairs=length(pairs)
    end
end

@testset "ISL analytic geometry and duration" begin
    positions = zeros(Float64, 2, 1, 3)
    velocities = zeros(Float64, 2, 1, 3)
    positions[1, 1, :] .= (7000.0, 0.0, 0.0)
    positions[2, 1, :] .= (7003.0, 4.0, 12.0)
    velocities[1, 1, :] .= (1.0, 2.0, 0.0)
    velocities[2, 1, :] .= (1.0, 2.0, 0.0)
    analytic = evaluate_isl_batch_gpu(
        positions,
        [(1, 2)];
        velocities=velocities,
        isl_max_range_km=100.0,
        isl_require_los=false,
        isl_min_duration_s=0.0,
    )
    @test analytic.available[1, 1]
    @test analytic.distance_km[1, 1] ≈ 13.0 atol=1e-12
    @test analytic.elevation_deg[1, 1] ≈ 13.342363797088238 atol=1e-12
    @test analytic.cos_psi[1, 1] ≈ 3 / sqrt(10) atol=1e-12
    @test analytic.duration_s[1, 1] == 300.0

    series = evaluate_isl_series(
        KernelComputeBackend(CPU(); precision=Float64),
        positions,
        [(1, 2)];
        velocities=velocities,
        isl_max_range_km=100.0,
        isl_require_los=false,
        isl_min_duration_s=0.0,
    )
    @test series.available == analytic.available
    @test series.elevation_deg[1, 1] ≈ 13.342363797088238 atol=1e-12
    @test series.cos_psi[1, 1] ≈ 3 / sqrt(10) atol=1e-12

    positions[1, 1, :] .= (7000.0, 1000.0, 2000.0)
    positions[2, 1, :] .= (7003.0, 1004.0, 2012.0)
    velocities[1, 1, :] .= (14000.0, 2000.0, 4000.0)
    velocities[2, 1, :] .= (0.0, 1.0, 0.0)
    degenerate = evaluate_isl_batch_gpu(
        positions,
        [(1, 2)];
        velocities=velocities,
        isl_max_range_km=100.0,
        isl_require_los=false,
        isl_max_cone_angle_deg=180.0,
        isl_min_duration_s=0.0,
    )
    @test !degenerate.available[1, 1]
    @test degenerate.elevation_deg[1, 1] == 90.0
    @test degenerate.cos_psi[1, 1] == 1.0
    @test degenerate.duration_s[1, 1] == 0.0

    positions32 = zeros(Float32, 2, 1, 3)
    velocities32 = zeros(Float32, 2, 1, 3)
    positions32[1, 1, :] .= (7000.0f0, 0.0f0, 0.0f0)
    positions32[2, 1, :] .= (7000.0f0, 0.0f0, 1.0f0)
    velocities32[1, 1, :] .= (0.0f0, 1.0f0, 0.0f0)
    velocities32[2, 1, :] .= (0.0f0, 1.0f0, 2.0f0^-12)
    long_duration = evaluate_isl_batch_gpu(
        positions32,
        [(1, 2)];
        velocities=velocities32,
        isl_max_range_km=4097.00048828125f0,
        isl_require_los=false,
        isl_min_duration_s=16_777_218.0f0,
        time_horizon_s=16_777_220.0f0,
    )
    @test long_duration.duration_s[1, 1] == 16_777_218.0f0
    @test long_duration.available[1, 1]
    too_short = evaluate_isl_batch_gpu(
        positions32,
        [(1, 2)];
        velocities=velocities32,
        isl_max_range_km=4097.00048828125f0,
        isl_require_los=false,
        isl_min_duration_s=16_777_220.0f0,
        time_horizon_s=16_777_220.0f0,
    )
    @test !too_short.available[1, 1]
    @test too_short.duration_s[1, 1] == 16_777_218.0f0
    huge_range = evaluate_isl_batch_gpu(
        positions32,
        [(1, 2)];
        velocities=velocities32,
        isl_max_range_km=1.0f20,
        isl_require_los=false,
        isl_min_duration_s=0.0,
    )
    @test huge_range.available[1, 1]
    @test huge_range.duration_s[1, 1] == 300.0f0
end

@testset "ISL orthogonal RTN and duration regression" begin
    # 1. Orthogonal RTN: geometry where the old non-orthogonal T=v/|v| would flip
    #    availability on the cos60° azimuth threshold. Satellite A has a velocity with
    #    both radial and tangential components; the correct orthogonal RTN gives
    #    cos_psi=0.8 (available) while T=v/|v| would give cos_psi≈-0.28 (unavailable).
    positions = zeros(Float64, 2, 1, 3)
    velocities = zeros(Float64, 2, 1, 3)
    positions[1, 1, :] .= (7000.0, 0.0, 0.0)
    positions[2, 1, :] .= (7001.0, 0.6, 0.8)
    velocities[1, 1, :] .= (-7.6, 7.6, 0.0)
    velocities[2, 1, :] .= (-7.6, 7.6, 0.0)

    gpu_rtn = evaluate_isl_batch_gpu(
        positions,
        [(1, 2)];
        velocities=velocities,
        isl_max_range_km=100.0,
        isl_require_los=false,
        isl_max_cone_angle_deg=60.0,
        isl_min_duration_s=0.0,
    )
    golden_rtn = GoldenISLReference.evaluate_isl_series(
        positions, [(1, 2)];
        velocities=velocities,
        max_range=100.0,
        require_los=false,
        cone_deg=60.0,
        min_duration=0.0,
    )

    @test gpu_rtn.available == golden_rtn.available
    @test gpu_rtn.available[1, 1]
    @test gpu_rtn.elevation_deg[1, 1] ≈ 45.0 atol=1e-12
    @test gpu_rtn.cos_psi[1, 1] ≈ 0.8 atol=1e-12
    @test isapprox(gpu_rtn.distance_km, golden_rtn.distance_km; rtol=1e-12, atol=1e-12)
    @test isapprox(gpu_rtn.delay_ms, golden_rtn.delay_ms; rtol=1e-12, atol=1e-12)

    rel = positions[2, 1, :] .- positions[1, 1, :]
    R = positions[1, 1, :] ./ norm(positions[1, 1, :])
    old_T = velocities[1, 1, :] ./ norm(velocities[1, 1, :])
    horizontal = rel .- dot(rel, R) .* R
    old_cos_psi = dot(rel, old_T) / norm(horizontal)
    @test old_cos_psi < 0.0  # old non-orthogonal T would reject this link

    # 2. Duration boundary around min_duration=10 s. Two satellites separated by 1 km
    #    along the cross-track direction, with a controlled relative velocity pushing
    #    them apart. Duration = (max_range - d) / |v_rel|.
    positions_d = zeros(Float64, 2, 1, 3)
    velocities_d = zeros(Float64, 2, 1, 3)
    positions_d[1, 1, :] .= (7000.0, 0.0, 0.0)
    positions_d[2, 1, :] .= (7000.0, 0.0, 1.0)
    velocities_d[1, 1, :] .= (0.0, 7.6, 0.0)

    # Crossing ≈ 9.5 s → unavailable when min_duration=10.
    v_rel_9_5 = 99.0 / 9.5
    velocities_d[2, 1, :] .= (0.0, 7.6, v_rel_9_5)
    gpu_short = evaluate_isl_batch_gpu(
        positions_d,
        [(1, 2)];
        velocities=velocities_d,
        isl_max_range_km=100.0,
        isl_require_los=false,
        isl_max_cone_angle_deg=180.0,
        isl_min_duration_s=10.0,
        time_horizon_s=300.0,
    )
    golden_short = GoldenISLReference.evaluate_isl_series(
        positions_d, [(1, 2)];
        velocities=velocities_d,
        max_range=100.0,
        require_los=false,
        cone_deg=180.0,
        min_duration=10.0,
        time_horizon=300.0,
    )
    @test gpu_short.available == golden_short.available
    @test !gpu_short.available[1, 1]
    @test gpu_short.duration_s[1, 1] ≈ 9.5 atol=1e-12

    # Crossing ≈ 10.5 s → available when min_duration=10.
    v_rel_10_5 = 99.0 / 10.5
    velocities_d[2, 1, :] .= (0.0, 7.6, v_rel_10_5)
    gpu_long = evaluate_isl_batch_gpu(
        positions_d,
        [(1, 2)];
        velocities=velocities_d,
        isl_max_range_km=100.0,
        isl_require_los=false,
        isl_max_cone_angle_deg=180.0,
        isl_min_duration_s=10.0,
        time_horizon_s=300.0,
    )
    golden_long = GoldenISLReference.evaluate_isl_series(
        positions_d, [(1, 2)];
        velocities=velocities_d,
        max_range=100.0,
        require_los=false,
        cone_deg=180.0,
        min_duration=10.0,
        time_horizon=300.0,
    )
    @test gpu_long.available == golden_long.available
    @test gpu_long.available[1, 1]
    @test gpu_long.duration_s[1, 1] ≈ 10.5 atol=1e-12

    # 3. Float32 variants of the same boundaries (Modal ran both f64/f32).
    positions32 = zeros(Float32, 2, 1, 3)
    velocities32 = zeros(Float32, 2, 1, 3)
    positions32[1, 1, :] .= (7000.0f0, 0.0f0, 0.0f0)
    positions32[2, 1, :] .= (7001.0f0, 0.6f0, 0.8f0)
    velocities32[1, 1, :] .= (-7.6f0, 7.6f0, 0.0f0)
    velocities32[2, 1, :] .= (-7.6f0, 7.6f0, 0.0f0)
    gpu_rtn32 = evaluate_isl_batch_gpu(
        positions32,
        [(1, 2)];
        velocities=velocities32,
        isl_max_range_km=100.0f0,
        isl_require_los=false,
        isl_max_cone_angle_deg=60.0f0,
        isl_min_duration_s=0.0f0,
    )
    golden_rtn32 = GoldenISLReference.evaluate_isl_series(
        positions32, [(1, 2)];
        velocities=velocities32,
        max_range=100.0f0,
        require_los=false,
        cone_deg=60.0f0,
        min_duration=0.0f0,
    )
    @test gpu_rtn32.available == golden_rtn32.available
    @test gpu_rtn32.available[1, 1]
    @test gpu_rtn32.elevation_deg[1, 1] ≈ 45.0f0 atol=1f-4
    @test gpu_rtn32.cos_psi[1, 1] ≈ 0.8f0 atol=1f-4

    positions32_d = zeros(Float32, 2, 1, 3)
    velocities32_d = zeros(Float32, 2, 1, 3)
    positions32_d[1, 1, :] .= (7000.0f0, 0.0f0, 0.0f0)
    positions32_d[2, 1, :] .= (7000.0f0, 0.0f0, 1.0f0)
    velocities32_d[1, 1, :] .= (0.0f0, 7.6f0, 0.0f0)

    v_rel_9_5_32 = Float32(99.0 / 9.5)
    velocities32_d[2, 1, :] .= (0.0f0, 7.6f0, v_rel_9_5_32)
    gpu_short32 = evaluate_isl_batch_gpu(
        positions32_d,
        [(1, 2)];
        velocities=velocities32_d,
        isl_max_range_km=100.0f0,
        isl_require_los=false,
        isl_max_cone_angle_deg=180.0f0,
        isl_min_duration_s=10.0f0,
        time_horizon_s=300.0f0,
    )
    golden_short32 = GoldenISLReference.evaluate_isl_series(
        positions32_d, [(1, 2)];
        velocities=velocities32_d,
        max_range=100.0f0,
        require_los=false,
        cone_deg=180.0f0,
        min_duration=10.0f0,
        time_horizon=300.0f0,
    )
    @test gpu_short32.available == golden_short32.available
    @test !gpu_short32.available[1, 1]
    @test gpu_short32.duration_s[1, 1] ≈ 9.5f0 atol=1f-3

    v_rel_10_5_32 = Float32(99.0 / 10.5)
    velocities32_d[2, 1, :] .= (0.0f0, 7.6f0, v_rel_10_5_32)
    gpu_long32 = evaluate_isl_batch_gpu(
        positions32_d,
        [(1, 2)];
        velocities=velocities32_d,
        isl_max_range_km=100.0f0,
        isl_require_los=false,
        isl_max_cone_angle_deg=180.0f0,
        isl_min_duration_s=10.0f0,
        time_horizon_s=300.0f0,
    )
    golden_long32 = GoldenISLReference.evaluate_isl_series(
        positions32_d, [(1, 2)];
        velocities=velocities32_d,
        max_range=100.0f0,
        require_los=false,
        cone_deg=180.0f0,
        min_duration=10.0f0,
        time_horizon=300.0f0,
    )
    @test gpu_long32.available == golden_long32.available
    @test gpu_long32.available[1, 1]
    @test gpu_long32.duration_s[1, 1] ≈ 10.5f0 atol=1f-3
end

@testset "evaluate_isl_batch_gpu validation" begin
    positions = zeros(Float64, 3, 4, 3)
    @test_throws ArgumentError evaluate_isl_batch_gpu(
        positions[:, :, 1:2], [(1, 2)],
    )
    @test_throws ArgumentError evaluate_isl_batch_gpu(
        positions, [(1, 9)],
    )
    @test_throws ArgumentError evaluate_isl_batch_gpu(
        positions, [(1, 1)],
    )
    empty = evaluate_isl_batch_gpu(positions, Tuple{Int,Int}[])
    @test size(empty.available) == (0, 4)

    positions32 = zeros(Float32, 3, 4, 3)
    @test_throws ArgumentError evaluate_isl_batch_gpu(
        positions32,
        Tuple{Int,Int}[];
        isl_max_range_km=floatmax(Float64),
    )
    @test_throws ArgumentError evaluate_isl_batch_gpu(
        positions32,
        Tuple{Int,Int}[];
        isl_max_cone_angle_deg=-1.0,
    )
    @test_throws ArgumentError evaluate_isl_batch_gpu(
        positions32,
        Tuple{Int,Int}[];
        isl_min_duration_s=-1.0,
    )
    @test_throws ArgumentError evaluate_isl_batch_gpu(
        positions32,
        Tuple{Int,Int}[];
        time_horizon_s=1.0e39,
    )
    @test_throws ArgumentError evaluate_isl_batch_gpu(
        positions32,
        Tuple{Int,Int}[];
        earth_radius_km=0.0,
    )
end

@testset "Kernel compute backend ISL contract" begin
    backend = KernelComputeBackend(CPU(); precision=Float64)
    for (n_sat, n_times) in ((12, 5), (24, 6))
        positions, velocities =
            random_isl_scenario(n_sat, n_times, Float64; seed=100 + n_sat + n_times)
        pairs = Tuple{Int,Int}[]
        for i in 1:n_sat, j in (i + 1):n_sat
            push!(pairs, (i, j))
        end

        # 位置-only 路径（距离 + LOS + 距离约束）
        ref0 = GoldenISLReference.evaluate_isl_series(positions, pairs)
        got0 = evaluate_isl_series(backend, positions, pairs)
        @test got0 isa ISLSeriesResult
        @test got0.available == ref0.available
        @test got0.line_of_sight == ref0.line_of_sight
        @test isapprox(got0.distance_km, ref0.distance_km; rtol=1e-9, atol=1e-9)
        @test isapprox(got0.delay_ms, ref0.delay_ms; rtol=1e-9, atol=1e-9)
        @test got0.metadata["backend"] == compute_backend_name(backend)

        # 带速度路径（RTN 仰角 / 方位 / 持续时长）
        ref1 = GoldenISLReference.evaluate_isl_series(
            positions, pairs; velocities=velocities,
        )
        got1 = evaluate_isl_series(backend, positions, pairs; velocities=velocities)
        @test got1.available == ref1.available
        @test isapprox(got1.distance_km, ref1.distance_km; rtol=1e-9, atol=1e-9)
        @test isapprox(got1.elevation_deg, ref1.elevation_deg; rtol=1e-8, atol=1e-8)
        @test isapprox(got1.cos_psi, ref1.cos_psi; rtol=1e-8, atol=1e-8)
        @test isapprox(got1.duration_s, ref1.duration_s; rtol=1e-6, atol=1e-6)
        @info "ISL series parity" n_sat n_times n_pairs=length(pairs)
    end

    @test compute_backend_capabilities(backend).operations ==
          (:gsl_series, :isl_series)

    # 空 pairs → (0, n_times)
    positions, _ = random_isl_scenario(8, 4, Float64; seed=1)
    empty_result = evaluate_isl_series(backend, positions, Tuple{Int,Int}[])
    @test empty_result isa ISLSeriesResult
    @test size(empty_result.available) == (0, 4)
    @test_throws ArgumentError evaluate_isl_series(
        backend,
        positions,
        [(1, 1)],
    )

    backend32 = KernelComputeBackend(CPU(); precision=Float32)
    @test_throws ArgumentError evaluate_isl_series(
        backend32,
        positions,
        Tuple{Int,Int}[];
        isl_max_range_km=floatmax(Float64),
    )
    @test_throws ArgumentError evaluate_isl_series(
        backend32,
        positions,
        Tuple{Int,Int}[];
        isl_min_duration_s=-1.0,
    )

    # 契约回退：generic evaluate_isl_series 对未实现该算子的后端抛 MethodError
    @test_throws MethodError evaluate_isl_series(
        CPUComputeBackend(), positions, [(1, 2)],
    )
end

@testset "device-resident reductions (GSL/ISL aggregates)" begin
    # ── GSL：每 (站,时) 可见卫星计数 + 每站可见时间比 ──
    for (n_satellites, n_stations, n_times) in ((66, 10, 30), (132, 20, 24))
        Random.seed!(500 + n_satellites + n_stations + n_times)
        positions = random_positions(n_satellites, n_times, Float64)
        stations = random_gsl_stations(n_stations)
        ground_ecef, ned_rotation = gsl_station_geometry(stations)

        full = evaluate_gsl_batch_gpu(
            positions, ground_ecef, ned_rotation;
            gsl_min_elevation_deg=25.0, gsl_max_range_km=2000.0,
        )
        golden = golden_gsl_batch(positions, stations)
        @test full[1] == golden[1]   # 前提：完整可见性与 golden 逐位一致

        counts = gsl_visible_counts_gpu(
            positions, ground_ecef, ned_rotation;
            gsl_min_elevation_deg=25.0, gsl_max_range_km=2000.0,
        )
        counts_full = dropdims(sum(full[1]; dims=1); dims=1)        # (M, NT)
        counts_golden = dropdims(sum(golden[1]; dims=1); dims=1)
        @test size(counts) == (n_stations, n_times)
        @test counts isa Array{Int32,2}
        @test counts == counts_full           # 设备聚合 == 完整数组再 host 归约
        @test counts == counts_golden         # 设备聚合 == golden 归约

        ratio = gsl_station_visible_ratio_gpu(
            positions, ground_ecef, ned_rotation;
            gsl_min_elevation_deg=25.0, gsl_max_range_km=2000.0,
        )
        ratio_full = [
            count(t -> any(@view full[1][:, m, t]), 1:n_times) / n_times
            for m in 1:n_stations
        ]
        @test length(ratio) == n_stations
        @test ratio == ratio_full
        @test ratio == dropdims(sum(counts .> 0; dims=2); dims=2) ./ n_times

        # 设备驻留：一次上传 → 设备聚合 → 只下载 (M,NT) 与 (M,)（不下载 (N,M,NT)）
        agg = device_pipeline(CPU(), positions, ground_ecef, ned_rotation) do p, g, n
            (
                counts=gsl_visible_counts_gpu(
                    p, g, n; gsl_min_elevation_deg=25.0, gsl_max_range_km=2000.0,
                ),
                ratio=gsl_station_visible_ratio_gpu(
                    p, g, n; gsl_min_elevation_deg=25.0, gsl_max_range_km=2000.0,
                ),
            )
        end
        @test agg.counts == counts
        @test agg.ratio == ratio
        @test agg.counts isa Array{Int32,2}
    end

    # Float32 后端可运行且形状/类型正确
    Random.seed!(777)
    p32 = Float32.(random_positions(66, 20, Float64))
    st = random_gsl_stations(8)
    ge64, nr64 = gsl_station_geometry(st)
    c32 = gsl_visible_counts_gpu(
        p32, Float32.(ge64), Float32.(nr64);
        gsl_min_elevation_deg=25.0f0, gsl_max_range_km=2000.0f0,
    )
    @test c32 isa Array{Int32,2}
    @test size(c32) == (8, 20)

    # ── ISL：每时刻可用链路数 + 每跳平均可用度 ──
    for (n_sat, n_times) in ((12, 5), (30, 8))
        positions, velocities =
            random_isl_scenario(n_sat, n_times, Float64; seed=600 + n_sat + n_times)
        pairs = Tuple{Int,Int}[]
        for i in 1:n_sat, j in (i + 1):n_sat
            push!(pairs, (i, j))
        end

        # 带速度路径
        full = evaluate_isl_batch_gpu(positions, pairs; velocities=velocities)
        golden = GoldenISLReference.evaluate_isl_series(
            positions, pairs; velocities=velocities,
        )
        @test full.available == golden.available

        counts = isl_available_counts_gpu(positions, pairs; velocities=velocities)
        @test length(counts) == n_times
        @test counts isa Array{Int32,1}
        @test counts == vec(sum(full.available; dims=1))     # == 完整数组沿 pair 维求和
        @test counts == vec(sum(golden.available; dims=1))

        ratio = isl_pair_available_ratio_gpu(positions, pairs; velocities=velocities)
        @test length(ratio) == length(pairs)
        @test ratio == vec(sum(full.available; dims=2)) ./ n_times

        # 每卫星可用链路度（连通度/邻接度指标）
        degree = isl_satellite_degree_gpu(positions, pairs; velocities=velocities)
        degree_ref = zeros(Int32, n_sat, n_times)
        for (pair_index, (i, j)) in enumerate(pairs), t in 1:n_times
            if full.available[pair_index, t]
                degree_ref[i, t] += Int32(1)
                degree_ref[j, t] += Int32(1)
            end
        end
        @test size(degree) == (n_sat, n_times)
        @test degree isa Array{Int32,2}
        @test degree == degree_ref
        # 度之和 = 2×每时刻可用链路数（每条可用链路贡献两个端点）
        @test vec(sum(degree; dims=1)) == 2 .* counts

        # 位置-only 路径（无速度）
        full0 = evaluate_isl_batch_gpu(positions, pairs)
        @test isl_available_counts_gpu(positions, pairs) ==
              vec(sum(full0.available; dims=1))
        @test isl_pair_available_ratio_gpu(positions, pairs) ==
              vec(sum(full0.available; dims=2)) ./ n_times

        # 设备驻留：只下载 (NT,) 与 (pairs,) 与 (N,NT)（不下载 (pairs,NT)）
        agg = device_pipeline(CPU(), positions, velocities) do p, v
            (
                counts=isl_available_counts_gpu(p, pairs; velocities=v),
                ratio=isl_pair_available_ratio_gpu(p, pairs; velocities=v),
                degree=isl_satellite_degree_gpu(p, pairs; velocities=v),
            )
        end
        @test agg.counts == counts
        @test agg.ratio == ratio
        @test agg.degree == degree
        @test agg.counts isa Array{Int32,1}
    end

    # 跨 workgroup 边界用例：n_pairs 小于、等于、大于块大小（128）以及不整除的情况
    for (n_sat, n_pairs, n_times) in ((8, 5, 3), (24, 130, 4), (40, 300, 6))
        positions, velocities =
            random_isl_scenario(n_sat, n_times, Float64; seed=900 + n_sat + n_pairs + n_times)
        all_pairs = [(i, j) for i in 1:n_sat for j in (i + 1):n_sat]
        pairs = all_pairs[1:min(n_pairs, length(all_pairs))]

        full = evaluate_isl_batch_gpu(positions, pairs; velocities=velocities)
        counts = isl_available_counts_gpu(positions, pairs; velocities=velocities)
        @test counts isa Vector{Int32}
        @test counts == vec(sum(full.available; dims=1))

        full0 = evaluate_isl_batch_gpu(positions, pairs)
        counts0 = isl_available_counts_gpu(positions, pairs)
        @test counts0 == vec(sum(full0.available; dims=1))
    end

    # 空 pairs → (NT,) 全零 / (0,) / (N,NT) 全零
    positions, _ = random_isl_scenario(8, 4, Float64; seed=1)
    @test isl_available_counts_gpu(positions, Tuple{Int,Int}[]) == zeros(Int32, 4)
    @test length(isl_pair_available_ratio_gpu(positions, Tuple{Int,Int}[])) == 0
    @test isl_satellite_degree_gpu(positions, Tuple{Int,Int}[]) == zeros(Int32, 8, 4)
    for reduction in (
        isl_available_counts_gpu,
        isl_pair_available_ratio_gpu,
        isl_satellite_degree_gpu,
    )
        @test_throws ArgumentError reduction(positions, [(1, 1)])
        @test_throws ArgumentError reduction(
            Float32.(positions),
            Tuple{Int,Int}[];
            time_horizon_s=1.0e39,
        )
    end
end

@testset "device residency pipeline" begin
    positions, velocities = random_isl_scenario(20, 6, Float64; seed=7)
    pairs = [(i, i + 1) for i in 1:19]
    direct = evaluate_isl_batch_gpu(positions, pairs; velocities=velocities)

    # 上传一次 → 设备上算 → 下载一次
    out = device_pipeline(CPU(), positions, velocities) do pos_d, vel_d
        evaluate_isl_batch_gpu(pos_d, pairs; velocities=vel_d)
    end
    @test out.available == direct.available
    @test isapprox(out.distance_km, direct.distance_km; rtol=1e-12, atol=1e-12)
    @test isapprox(out.elevation_deg, direct.elevation_deg; rtol=1e-12, atol=1e-12)
    @test isapprox(out.duration_s, direct.duration_s; rtol=1e-12, atol=1e-12)
    @test out.available isa Array{Bool}
    @test out.distance_km isa Array{Float64}

    # to_device / to_host 往返
    @test to_host(to_device(CPU(), positions)) == positions
end

@testset "coverage_loss_gpu adjoint (finite-difference)" begin
    Random.seed!(11)
    n_sat, n_times, n_lat, n_lon = 8, 4, 4, 6
    positions = Array{Float64}(undef, n_sat, n_times, 3)
    for s in 1:n_sat, t in 1:n_times
        dir = randn(3)
        dir ./= sqrt(sum(abs2, dir))
        positions[s, t, :] .= (6900.0 + 50 * rand()) .* dir
    end
    ground_pts, weights = random_ground_grid(n_lat, n_lon, Float64)
    kw = (min_el=10.0, τ_cov=5.0, dt=1.0, τ_revisit=1.0, λ=0.1)

    y, pb = ChainRulesCore.rrule(coverage_loss_gpu, positions, ground_pts, weights; kw...)
    @test y == coverage_loss_gpu(positions, ground_pts, weights; kw...)
    _, gradP, _, _ = pb(1.0)
    @test size(gradP) == size(positions)

    h = 1e-3
    for _ in 1:12
        s = rand(1:n_sat)
        t = rand(1:n_times)
        c = rand(1:3)
        Pp = copy(positions); Pp[s, t, c] += h
        Pm = copy(positions); Pm[s, t, c] -= h
        fd = (coverage_loss_gpu(Pp, ground_pts, weights; kw...) -
              coverage_loss_gpu(Pm, ground_pts, weights; kw...)) / (2h)
        @test isapprox(gradP[s, t, c], fd; atol=1e-5, rtol=1e-3)
    end

    saturated_positions = reshape([7000.0, 0.0, 0.0], 1, 1, 3)
    saturated_ground = reshape([6378.137, 0.0, 0.0], 1, 3)
    saturated_weights = [1.0]
    _, saturated_pullback = ChainRulesCore.rrule(
        coverage_loss_gpu,
        saturated_positions,
        saturated_ground,
        saturated_weights;
        min_el=-90.0,
        τ_cov=1e-3,
        dt=1.0,
        τ_revisit=1.0,
        λ=0.1,
    )
    _, saturated_gradient, _, _ = saturated_pullback(1.0)
    @test all(isfinite, saturated_gradient)
    @test all(iszero, saturated_gradient)
end

@testset "Float32 cutoff policy" begin
    station = [(0.0, 0.0, 0.0)]
    positions = reshape([8378.13701, 0.0, 0.0], 1, 1, 3)
    result64 = evaluate_gsl_series(
        KernelComputeBackend(CPU(); precision=Float64),
        positions,
        station;
        gsl_min_elevation_deg=25.0,
        gsl_max_range_km=2000.0,
    )
    result32 = evaluate_gsl_series(
        KernelComputeBackend(CPU(); precision=Float32),
        positions,
        station;
        gsl_min_elevation_deg=25.0,
        gsl_max_range_km=2000.0,
    )

    @test !result64.available[1, 1, 1]
    @test result32.available[1, 1, 1]
    @test abs(result64.distance_km[1, 1, 1] - 2000.0) <= 1e-4
    @test abs(result32.distance_km[1, 1, 1] - 2000.0) <= 1e-3
end

include(joinpath(GOLDEN_DIR, "golden_propagator_reference.jl"))

function random_kepler_elements(n_sat, ::Type{T}; seed=0) where {T}
    Random.seed!(seed)
    sma = Vector{T}(undef, n_sat)
    ecc = Vector{T}(undef, n_sat)
    inc = Vector{T}(undef, n_sat)
    raan = Vector{T}(undef, n_sat)
    argp = Vector{T}(undef, n_sat)
    nu = Vector{T}(undef, n_sat)
    for s in 1:n_sat
        sma[s] = T(6771.0 + 400.0 * rand())            # LEO：高度约 393–793 km
        ecc[s] = T(0.0005 + 0.02 * rand())             # 近圆
        inc[s] = T(deg2rad(30.0 + 120.0 * rand()))
        raan[s] = T(deg2rad(360.0 * rand()))
        argp[s] = T(deg2rad(360.0 * rand()))
        nu[s] = T(deg2rad(360.0 * rand()))
    end
    return sma, ecc, inc, raan, argp, nu
end

# SatelliteToolbox 参考：与 src/orbit 的 propagate_positions 同一算法（step! 累进 Δt）。
function satellitetoolbox_series(sma, ecc, inc, raan, argp, nu, tspan, model)
    n_sat = length(sma)
    n_times = length(tspan)
    out = Array{Float64}(undef, n_sat, n_times, 3)
    val = model === :j2 ? Val(:J2) : Val(:TwoBody)
    for s in 1:n_sat
        el = SatelliteToolbox.KeplerianElements(
            0.0, Float64(sma[s]) * 1000, Float64(ecc[s]),
            Float64(inc[s]), Float64(raan[s]), Float64(argp[s]), Float64(nu[s]),
        )
        prop = SatelliteToolbox.Propagators.init(val, el)
        for (time_index, t) in enumerate(tspan)
            Δt = time_index == 1 ? tspan[1] : tspan[time_index] - tspan[time_index - 1]
            sv = SatelliteToolbox.Propagators.step!(
                prop, Float64(Δt), SatelliteToolbox.OrbitStateVector,
            )
            out[s, time_index, 1] = sv.r[1] / 1000
            out[s, time_index, 2] = sv.r[2] / 1000
            out[s, time_index, 3] = sv.r[3] / 1000
        end
    end
    return out
end

# Modern UT1 epoch used to ensure frame tests cannot accidentally preserve a JD0 convention.
const FRAME_TEST_EPOCH_JD_UT1 = 2461234.5  # 2026-07-13 00:00 UT1 (UTC approximation)

function satellitetoolbox_teme_to_pef(teme, elapsed_s, epoch_jd_ut1)
    out = Array{Float64}(undef, size(teme))
    for (time_index, elapsed) in enumerate(elapsed_s)
        D = SatelliteToolbox.r_eci_to_ecef(
            SatelliteToolbox.TEME(),
            SatelliteToolbox.PEF(),
            Float64(epoch_jd_ut1) + Float64(elapsed) / 86400.0,
        )
        for s in 1:size(teme, 1)
            v = Float64.(@view teme[s, time_index, :])
            r = D * v
            out[s, time_index, 1] = r[1]
            out[s, time_index, 2] = r[2]
            out[s, time_index, 3] = r[3]
        end
    end
    return out
end

# Independent modern-epoch reference: SatelliteToolbox propagation followed by its TEME→PEF map.
function satellitetoolbox_series_pef(
    sma, ecc, inc, raan, argp, nu, elapsed_s, model;
    epoch_jd_ut1,
)
    teme = satellitetoolbox_series(sma, ecc, inc, raan, argp, nu, elapsed_s, model)
    return satellitetoolbox_teme_to_pef(teme, elapsed_s, epoch_jd_ut1)
end

@testset "propagate_kepler_gpu analytic parity" begin
    for model in (:two_body, :j2)
        sma, ecc, inc, raan, argp, nu =
            random_kepler_elements(20, Float64; seed=(model === :j2 ? 2 : 1))
        tspan = collect(0.0:120.0:3600.0)   # 0..1h，31 个时刻

        # 1) 设备核（KA CPU 后端）vs 冻结 golden 标量：机器精度对齐（主对标）
        golden = GoldenPropagatorReference.propagate_series(
            sma, ecc, inc, raan, argp, nu, tspan; model=model,
        )
        got = propagate_kepler_gpu(sma, ecc, inc, raan, argp, nu, tspan; model=model)
        @test got isa Array{Float64,3}
        @test size(got) == (20, length(tspan), 3)
        @test isapprox(got, golden; rtol=1e-9, atol=1e-7)

        # 2) 交叉验证 vs SatelliteToolbox（src/orbit propagate_positions/J2 所封装）
        reference = satellitetoolbox_series(sma, ecc, inc, raan, argp, nu, tspan, model)
        @test isapprox(got, reference; rtol=1e-7, atol=1e-5)
        @info "propagator parity" model max_abs_err_km=maximum(abs.(got .- reference))
    end

    # 3) 设备驻留：元素上设备 → 设备上传播 → ISL 直接吃设备位置（省 host 往返）
    sma, ecc, inc, raan, argp, nu = random_kepler_elements(12, Float64; seed=9)
    tspan = collect(0.0:300.0:1800.0)
    pairs = [(i, i + 1) for i in 1:11]
    host_pos = propagate_kepler_gpu(sma, ecc, inc, raan, argp, nu, tspan; model=:j2)
    isl_host = evaluate_isl_batch_gpu(host_pos, pairs)
    out = device_pipeline(CPU(), sma, ecc, inc, raan, argp, nu, tspan) do a, e, i, om, w, v, ts
        pos_d = propagate_kepler_gpu(a, e, i, om, w, v, ts; model=:j2)
        evaluate_isl_batch_gpu(pos_d, pairs)
    end
    @test out.available == isl_host.available
    @test isapprox(out.distance_km, isl_host.distance_km; rtol=1e-12, atol=1e-12)

    # 4) Float32 后端可运行且物理正确（放宽容差，短时段限制舍入累积）
    sma32, ecc32, inc32, raan32, argp32, nu32 =
        random_kepler_elements(16, Float32; seed=5)
    tspan32 = collect(Float32, 0.0:60.0:600.0)
    golden32 = GoldenPropagatorReference.propagate_series(
        Float64.(sma32), Float64.(ecc32), Float64.(inc32),
        Float64.(raan32), Float64.(argp32), Float64.(nu32),
        Float64.(tspan32); model=:two_body,
    )
    got32 = propagate_kepler_gpu(
        sma32, ecc32, inc32, raan32, argp32, nu32, tspan32; model=:two_body,
    )
    @test got32 isa Array{Float32,3}
    @test all(isfinite, got32)
    @test isapprox(Float64.(got32), golden32; rtol=1e-2, atol=2.0)

    # 5) 校验：非法 model / 长度不一致
    @test_throws ArgumentError propagate_kepler_gpu(
        sma, ecc, inc, raan, argp, nu, tspan; model=:sgp4,
    )
    @test_throws ArgumentError propagate_kepler_gpu(
        sma[1:3], ecc, inc, raan, argp, nu, tspan,
    )
end

@testset "teme_to_pef_gpu explicit modern epoch" begin
    base_vectors = (
        (7000.0, 0.0, 0.0),
        (-1000.0, 6800.0, 1200.0),
        (1234.5, -5678.0, 3456.0),
    )
    elapsed64 = [0.0, 60.0, 3600.0, 43200.0, 86400.0]

    for T in (Float64, Float32)
        elapsed = T.(elapsed64)
        teme = Array{T}(undef, length(base_vectors), length(elapsed), 3)
        for sat in eachindex(base_vectors), time_index in eachindex(elapsed)
            teme[sat, time_index, 1] = T(base_vectors[sat][1])
            teme[sat, time_index, 2] = T(base_vectors[sat][2])
            teme[sat, time_index, 3] = T(base_vectors[sat][3])
        end

        got = teme_to_pef_gpu(
            teme,
            elapsed;
            epoch_jd_ut1=FRAME_TEST_EPOCH_JD_UT1,
        )
        reference = satellitetoolbox_teme_to_pef(
            teme,
            elapsed,
            FRAME_TEST_EPOCH_JD_UT1,
        )
        rtol = T === Float64 ? 5e-11 : 5e-6
        atol = T === Float64 ? 2e-5 : 2e-2
        @test got isa Array{T,3}
        @test isapprox(Float64.(got), reference; rtol=rtol, atol=atol)

        # Host-precomputed kernel coefficients and elapsed-time array stay in position precision.
        coefficients =
            SatelliteSimGPU._gmst_epoch_coefficients(FRAME_TEST_EPOCH_JD_UT1, T)
        @test coefficients isa NTuple{5,T}

        # Same target JD expressed by shifting one day between epoch and elapsed time.
        fixed_teme = teme[:, 1:1, :]
        from_elapsed_day = teme_to_pef_gpu(
            fixed_teme,
            T[86400];
            epoch_jd_ut1=FRAME_TEST_EPOCH_JD_UT1,
        )
        from_epoch_day = teme_to_pef_gpu(
            fixed_teme,
            T[0];
            epoch_jd_ut1=FRAME_TEST_EPOCH_JD_UT1 + 1,
        )
        @test isapprox(
            Float64.(from_elapsed_day),
            Float64.(from_epoch_day);
            rtol=rtol,
            atol=atol,
        )
    end

    teme = zeros(Float64, 2, 3, 3)
    elapsed = [0.0, 60.0, 120.0]
    @test_throws UndefKeywordError teme_to_pef_gpu(teme, elapsed)
    @test_throws ArgumentError teme_to_pef_gpu(
        teme, elapsed; epoch_jd_ut1=NaN,
    )
    @test_throws ArgumentError teme_to_pef_gpu(
        teme, [0.0, Inf, 120.0]; epoch_jd_ut1=FRAME_TEST_EPOCH_JD_UT1,
    )
    invalid_teme = copy(teme)
    invalid_teme[1, 1, 1] = NaN
    @test_throws ArgumentError teme_to_pef_gpu(
        invalid_teme, elapsed; epoch_jd_ut1=FRAME_TEST_EPOCH_JD_UT1,
    )
    @test_throws ArgumentError teme_to_pef_gpu(
        teme, elapsed[1:2]; epoch_jd_ut1=FRAME_TEST_EPOCH_JD_UT1,
    )
    @test_throws ArgumentError teme_to_pef_gpu(
        teme[:, :, 1:2], elapsed; epoch_jd_ut1=FRAME_TEST_EPOCH_JD_UT1,
    )
end

@testset "propagate_to_pef_gpu modern-epoch parity" begin
    for model in (:two_body, :j2)
        sma, ecc, inc, raan, argp, nu =
            random_kepler_elements(18, Float64; seed=(model === :j2 ? 4 : 3))
        tspan = collect(0.0:150.0:5400.0)   # 0..1.5h

        golden_pef = GoldenPropagatorReference.propagate_series_pef(
            sma, ecc, inc, raan, argp, nu, tspan;
            epoch_jd_ut1=FRAME_TEST_EPOCH_JD_UT1,
            model=model,
        )
        got_pef = propagate_to_pef_gpu(
            sma, ecc, inc, raan, argp, nu, tspan;
            epoch_jd_ut1=FRAME_TEST_EPOCH_JD_UT1,
            model=model,
        )
        @test got_pef isa Array{Float64,3}
        @test size(got_pef) == (18, length(tspan), 3)
        @test isapprox(got_pef, golden_pef; rtol=1e-9, atol=2e-5)

        # Independent oracle: SatelliteToolbox propagation and frame conversion at a real epoch.
        reference_pef = satellitetoolbox_series_pef(
            sma, ecc, inc, raan, argp, nu, tspan, model;
            epoch_jd_ut1=FRAME_TEST_EPOCH_JD_UT1,
        )
        @test isapprox(got_pef, reference_pef; rtol=1e-7, atol=2e-5)
        @info "PEF parity vs SatelliteToolbox" model max_abs_err_km=maximum(
            abs.(got_pef .- reference_pef)
        )
    end

    # Standalone frame conversion and chained propagation agree without changing relative time.
    sma, ecc, inc, raan, argp, nu = random_kepler_elements(10, Float64; seed=8)
    tspan = collect(0.0:300.0:3600.0)
    teme = propagate_kepler_gpu(sma, ecc, inc, raan, argp, nu, tspan; model=:j2)
    pef_standalone = teme_to_pef_gpu(
        teme, tspan; epoch_jd_ut1=FRAME_TEST_EPOCH_JD_UT1,
    )
    pef_chained = propagate_to_pef_gpu(
        sma, ecc, inc, raan, argp, nu, tspan;
        epoch_jd_ut1=FRAME_TEST_EPOCH_JD_UT1,
        model=:j2,
    )
    @test pef_standalone == pef_chained
    @test !isapprox(pef_standalone, teme)
    for s in 1:10, tj in 1:length(tspan)
        r_teme = sqrt(sum(abs2, @view teme[s, tj, :]))
        r_pef = sqrt(sum(abs2, @view pef_standalone[s, tj, :]))
        @test isapprox(r_teme, r_pef; rtol=1e-11, atol=1e-7)
    end

    # Float32 propagation remains relative-time based; only the frame boundary sees the epoch.
    sma32, ecc32, inc32, raan32, argp32, nu32 =
        random_kepler_elements(12, Float32; seed=6)
    tspan32 = collect(Float32, 0.0:120.0:1200.0)
    got32 = propagate_to_pef_gpu(
        sma32, ecc32, inc32, raan32, argp32, nu32, tspan32;
        epoch_jd_ut1=FRAME_TEST_EPOCH_JD_UT1,
        model=:two_body,
    )
    @test got32 isa Array{Float32,3}
    @test all(isfinite, got32)

    @test_throws UndefKeywordError propagate_to_pef_gpu(
        sma, ecc, inc, raan, argp, nu, tspan,
    )
end

@testset "device residency: 元素→传播→TEME→PEF→GSL/覆盖 全程设备" begin
    sma, ecc, inc, raan, argp, nu = random_kepler_elements(24, Float64; seed=11)
    tspan = collect(0.0:120.0:1800.0)
    stations = random_gsl_stations(8)
    ground_ecef, ned_rotation = gsl_station_geometry(stations)
    ground_pts, weights = random_ground_grid(6, 8, Float64)

    # host 基线（相同 GPU 函数，host 驻留）
    host_pef = propagate_to_pef_gpu(
        sma, ecc, inc, raan, argp, nu, tspan;
        epoch_jd_ut1=FRAME_TEST_EPOCH_JD_UT1,
        model=:j2,
    )
    host_gsl = evaluate_gsl_batch_gpu(
        host_pef, ground_ecef, ned_rotation;
        gsl_min_elevation_deg=25.0, gsl_max_range_km=2000.0,
    )
    host_cov = coverage_loss_gpu(
        host_pef, ground_pts, weights;
        min_el=10.0, τ_cov=5.0, dt=1.0, τ_revisit=1.0, λ=0.1,
    )

    # 全程设备驻留：元素 + 站点几何一次上传 → 设备传播 → 设备 TEME→PEF → 设备 GSL → 一次下载
    gsl_out = device_pipeline(
        CPU(), sma, ecc, inc, raan, argp, nu, tspan, ground_ecef, ned_rotation,
    ) do a, e, i, om, w, v, ts, ge, nr
        pos_pef = propagate_to_pef_gpu(
            a, e, i, om, w, v, ts;
            epoch_jd_ut1=FRAME_TEST_EPOCH_JD_UT1,
            model=:j2,
        )
        evaluate_gsl_batch_gpu(
            pos_pef, ge, nr; gsl_min_elevation_deg=25.0, gsl_max_range_km=2000.0,
        )
    end
    @test gsl_out[1] == host_gsl[1]
    @test isapprox(gsl_out[2], host_gsl[2]; rtol=1e-12, atol=1e-12)
    @test isapprox(gsl_out[3], host_gsl[3]; rtol=1e-12, atol=1e-12)
    @test isapprox(gsl_out[4], host_gsl[4]; rtol=1e-12, atol=1e-12)
    @test any(gsl_out[1])   # 物理 sanity：PEF 对齐地面站后确有可见 GSL

    # 全程设备驻留：→ 覆盖损失（标量）
    cov_out = device_pipeline(
        CPU(), sma, ecc, inc, raan, argp, nu, tspan, ground_pts, weights,
    ) do a, e, i, om, w, v, ts, gp, wt
        pos_pef = propagate_to_pef_gpu(
            a, e, i, om, w, v, ts;
            epoch_jd_ut1=FRAME_TEST_EPOCH_JD_UT1,
            model=:j2,
        )
        coverage_loss_gpu(
            pos_pef, gp, wt; min_el=10.0, τ_cov=5.0, dt=1.0, τ_revisit=1.0, λ=0.1,
        )
    end
    @test isapprox(cov_out, host_cov; rtol=1e-12, atol=1e-12)

    # TEME 直接喂 GSL（未对齐地固站）与 PEF 的可见性不同。
    teme = propagate_kepler_gpu(sma, ecc, inc, raan, argp, nu, tspan; model=:j2)
    gsl_from_teme = evaluate_gsl_batch_gpu(
        teme, ground_ecef, ned_rotation;
        gsl_min_elevation_deg=25.0, gsl_max_range_km=2000.0,
    )
    @info "PEF vs TEME GSL visibility" pef_visible=sum(host_gsl[1]) teme_visible=sum(
        gsl_from_teme[1]
    )
end

include(joinpath(GOLDEN_DIR, "golden_sgp4_reference.jl"))

# 生成近地 SGP4 平均根数：n₀ 由半长轴反推（rad/min），角度 rad，bstar 小阻力。
function random_sgp4_elements(n_sat; seed=0, a_range=(6700.0, 7200.0), e_range=(0.001, 0.02))
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

@testset "sgp4_propagate_gpu near-Earth parity (vs SatelliteToolbox)" begin
    # 主对标：近地 :sgp4（近地点≥220km）与 :sgp4_lowper（低近地点截断）两分支
    for (label, seed, a_range, e_range, want_algo) in (
        ("sgp4", 41, (6750.0, 7200.0), (0.001, 0.02), Int32(1)),
        ("sgp4_lowper", 42, (6560.0, 6605.0), (0.0005, 0.0030), Int32(0)),
    )
        n0, e0, i0, raan, argp, M0, bstar =
            random_sgp4_elements(24; seed=seed, a_range=a_range, e_range=e_range)
        tspan = collect(0.0:10.0:120.0)   # 0..2h，分钟

        gold_pos, gold_vel = GoldenSGP4Reference.propagate_series(
            n0, e0, i0, raan, argp, M0, bstar, tspan,
        )
        el = sgp4_init_host(n0, e0, i0, raan, argp, M0, bstar)
        pos, vel = sgp4_propagate_gpu(el, tspan; velocities=true)

        @test pos isa Array{Float64,3}
        @test size(pos) == (24, length(tspan), 3)
        @test want_algo in el.algo          # 该分支确被触发
        pos_err = maximum(abs.(pos .- gold_pos))
        vel_err = maximum(abs.(vel .- gold_vel))
        @test pos_err < 1e-6                 # ≈机器精度（近地 SGP4 位置逐位对齐参考）
        @test vel_err < 1e-9
        @info "SGP4 parity" branch=label algos=Tuple(sort(unique(el.algo))) max_pos_err_km=pos_err max_vel_err_km_s=vel_err
    end

    # SGP4 TEME positions composed with the explicit modern-epoch PEF conversion.
    n0, e0, i0, raan, argp, M0, bstar = random_sgp4_elements(8; seed=43)
    tspan_min = [0.0, 10.0, 30.0, 60.0]
    elapsed_s = 60.0 .* tspan_min
    reference_teme, _ = GoldenSGP4Reference.propagate_series(
        n0, e0, i0, raan, argp, M0, bstar, tspan_min,
    )
    reference_pef = satellitetoolbox_teme_to_pef(
        reference_teme,
        elapsed_s,
        FRAME_TEST_EPOCH_JD_UT1,
    )
    elements = sgp4_init_host(n0, e0, i0, raan, argp, M0, bstar)
    candidate_teme = sgp4_propagate_gpu(elements, tspan_min)
    candidate_pef = teme_to_pef_gpu(
        candidate_teme,
        elapsed_s;
        epoch_jd_ut1=FRAME_TEST_EPOCH_JD_UT1,
    )
    @test isapprox(candidate_pef, reference_pef; rtol=1e-9, atol=2e-5)

    # 深空（周期 ≥ 225 min）→ 明确抛错（本档不支持 SDP4）
    mu = 398600.5
    a_deep = 20000.0
    n0_deep = [sqrt(mu / a_deep^3) * 60]
    @test_throws ArgumentError sgp4_init_host(
        n0_deep, [0.01], [deg2rad(55.0)], [0.0], [0.0], [0.0], [0.0],
    )

    # 校验：向量长度不一致 / n₀ 非正
    n0, e0, i0, raan, argp, M0, bstar = random_sgp4_elements(4; seed=7)
    @test_throws ArgumentError sgp4_init_host(n0[1:3], e0, i0, raan, argp, M0, bstar)
    @test_throws ArgumentError sgp4_init_host(
        [-1.0, 0.06, 0.06, 0.06], e0, i0, raan, argp, M0, bstar,
    )

    # 设备驻留：SGP4(TEME) → ISL 全程设备（元素一次上传 → 设备传播 → 设备 ISL → 一次下载）
    n0, e0, i0, raan, argp, M0, bstar = random_sgp4_elements(12; seed=9)
    tspan = collect(0.0:30.0:180.0)
    pairs = [(i, i + 1) for i in 1:11]
    el = sgp4_init_host(n0, e0, i0, raan, argp, M0, bstar)
    pos_h, vel_h = sgp4_propagate_gpu(el, tspan; velocities=true)
    isl_host = evaluate_isl_batch_gpu(pos_h, pairs; velocities=vel_h)
    out = device_pipeline(CPU(), el, tspan) do e, ts
        p, v = sgp4_propagate_gpu(e, ts; velocities=true)
        evaluate_isl_batch_gpu(p, pairs; velocities=v)
    end
    @test out.available == isl_host.available
    @test isapprox(out.distance_km, isl_host.distance_km; rtol=1e-12, atol=1e-12)

    # Float32 后端可运行、有限，且短时段内与 Float64 golden 物理接近
    n0, e0, i0, raan, argp, M0, bstar = random_sgp4_elements(16; seed=5)
    tspan32 = collect(Float32, 0.0:10.0:60.0)
    gold32, _ = GoldenSGP4Reference.propagate_series(
        n0, e0, i0, raan, argp, M0, bstar, Float64.(tspan32),
    )
    el32 = sgp4_init_host(
        Float32.(n0), Float32.(e0), Float32.(i0),
        Float32.(raan), Float32.(argp), Float32.(M0), Float32.(bstar),
    )
    pos32 = sgp4_propagate_gpu(el32, tspan32)
    @test pos32 isa Array{Float32,3}
    @test all(isfinite, pos32)
    @test isapprox(Float64.(pos32), gold32; rtol=1e-2, atol=5.0)
end

include("adjoint_contract_regression.jl")
include("orbit_validation_regression.jl")

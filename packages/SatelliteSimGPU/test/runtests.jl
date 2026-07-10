using Test
using Random
using KernelAbstractions
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

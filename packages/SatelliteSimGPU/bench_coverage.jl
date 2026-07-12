using Printf
using Random
using KernelAbstractions
using SatelliteSimGPU

const GOLDEN_DIR = joinpath(@__DIR__, "golden")
include(joinpath(GOLDEN_DIR, "golden_reference.jl"))

function ground_grid(n_lat, n_lon, T)
    lats = n_lat == 1 ? T[0] :
           range(T(deg2rad(-70.0)), T(deg2rad(70.0)); length=n_lat)
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

function positions(n_sat, n_times, T)
    output = Array{T}(undef, n_sat, n_times, 3)
    for sat in 1:n_sat, time_index in 1:n_times
        direction = randn(T, 3)
        direction ./= sqrt(sum(abs2, direction))
        output[sat, time_index, :] .= T(6900.0) .* direction
    end
    return output
end

function parse_args(args)
    length(args) == 3 || error(
        "usage: julia --project=. bench_coverage.jl N NT G",
    )
    return parse.(Int, args)
end

n_sat, n_times, n_ground = parse_args(ARGS)
all(>(0), (n_sat, n_times, n_ground)) ||
    error("N, NT, and G must be positive")
n_lat = max(1, floor(Int, sqrt(n_ground)))
n_lon = cld(n_ground, n_lat)
Random.seed!(1234)
pos = positions(n_sat, n_times, Float64)
ground_pts, weights = ground_grid(n_lat, n_lon, Float64)
ground_pts = ground_pts[1:n_ground, :]
weights = weights[1:n_ground]

reference = GoldenReference.coverage_loss(pos, ground_pts, weights)
candidate = coverage_loss_gpu(pos, ground_pts, weights)
GC.gc()

reference_time = @elapsed reference = GoldenReference.coverage_loss(
    pos, ground_pts, weights,
)
kernel_time = @elapsed candidate = coverage_loss_gpu(
    pos, ground_pts, weights,
)
backend = get_backend(pos)

relative_error = abs(candidate - reference) / max(abs(reference), eps())
@printf("N=%d NT=%d G=%d\n", n_sat, n_times, n_ground)
@printf("%-20s %12s %16s\n", "implementation", "seconds", "loss")
@printf("%-20s %12.6f %16.9e\n", "cpu_reference", reference_time, reference)
@printf("%-20s %12.6f %16.9e\n", "ka_cpu_kernel", kernel_time, candidate)
@printf("backend=%s device=cpu\n", string(typeof(backend)))
@printf("relative_error=%.6e\n", relative_error)

using CUDA
using Printf
using SatelliteToolbox
using SatelliteSimGPU

CUDA.allowscalar(false)

const PACKAGE_DIR = dirname(dirname(pathof(SatelliteSimGPU)))
const GOLDEN_DIR = joinpath(PACKAGE_DIR, "golden")
include(joinpath(GOLDEN_DIR, "golden_orbit_reference.jl"))

function orbital_elements(n_satellites, T)
    elements = Matrix{T}(undef, n_satellites, 6)
    for satellite_index in 1:n_satellites
        phase = T(2π * (satellite_index - 1) / n_satellites)
        elements[satellite_index, 1] =
            T(6_378_137.0 + 550_000.0 + 2_000.0 * mod(satellite_index, 7))
        elements[satellite_index, 2] =
            T(0.0001 + 0.0008 * mod(satellite_index, 5) / 4)
        elements[satellite_index, 3] =
            T(deg2rad(45.0 + 35.0 * mod(satellite_index, 9) / 8))
        elements[satellite_index, 4] = T(mod(phase * 3, 2π))
        elements[satellite_index, 5] = T(mod(phase * 5 + 0.1, 2π))
        elements[satellite_index, 6] = phase
    end
    return elements
end

function teme_to_pef_rotations(times, T)
    rotations = Array{T}(undef, length(times), 3, 3)
    for (time_index, elapsed_s) in pairs(times)
        rotation = SatelliteToolbox.r_eci_to_ecef(
            SatelliteToolbox.TEME(),
            SatelliteToolbox.PEF(),
            Float64(elapsed_s) / 86_400.0,
        )
        rotations[time_index, :, :] .= T.(rotation)
    end
    return rotations
end

function minimum_elapsed(samples, operation)
    times = Vector{Float64}(undef, samples)
    result = nothing
    for index in eachindex(times)
        times[index] = @elapsed result = operation()
    end
    return minimum(times), result
end

function benchmark(n_satellites, n_times, propagator)
    elements = orbital_elements(n_satellites, Float64)
    times = collect(range(0.0, 86_400.0; length=n_times))

    rotations = teme_to_pef_rotations(times, Float64)
    rotation_time, rotations =
        minimum_elapsed(3, () -> teme_to_pef_rotations(times, Float64))

    reference =
        GoldenOrbitReference.independent_positions(elements, times, propagator)
    reference_time, reference = minimum_elapsed(
        3,
        () -> GoldenOrbitReference.independent_positions(
            elements,
            times,
            propagator,
        ),
    )

    upload_time = @elapsed begin
        elements_d = CuArray(elements)
        times_d = CuArray(times)
        rotations_d = CuArray(rotations)
        CUDA.synchronize()
    end

    candidate_d = independent_positions_gpu(
        elements_d,
        times_d,
        rotations_d;
        propagator=propagator,
    )
    CUDA.synchronize()

    compute_time, candidate_d = minimum_elapsed(
        5,
        () -> begin
            result = independent_positions_gpu(
                elements_d,
                times_d,
                rotations_d;
                propagator=propagator,
            )
            CUDA.synchronize()
            return result
        end,
    )

    download_time = @elapsed candidate = Array(candidate_d)
    absolute_error = maximum(abs.(candidate .- reference))
    relative_error = maximum(
        abs.(candidate .- reference) ./ max.(abs.(reference), eps(Float64)),
    )
    pipeline_time =
        rotation_time + upload_time + compute_time + download_time

    @printf(
        "N=%d NT=%d propagator=%s\n",
        n_satellites,
        n_times,
        String(propagator),
    )
    @printf("cpu_reference_seconds=%.6f\n", reference_time)
    @printf("host_rotation_seconds=%.6f\n", rotation_time)
    @printf("h2d_upload_seconds=%.6f\n", upload_time)
    @printf("gpu_compute_seconds=%.6f\n", compute_time)
    @printf("d2h_download_seconds=%.6f\n", download_time)
    @printf("gpu_compute_speedup=%.6f\n", reference_time / compute_time)
    @printf("pipeline_speedup=%.6f\n", reference_time / pipeline_time)
    @printf("maximum_absolute_error_km=%.6e\n", absolute_error)
    @printf("maximum_relative_error=%.6e\n", relative_error)
end

length(ARGS) in (2, 3) ||
    error("usage: bench_orbit_cuda.jl N NT [two_body|j2|j4]")
n_satellites = parse(Int, ARGS[1])
n_times = parse(Int, ARGS[2])
propagator = length(ARGS) == 3 ? Symbol(ARGS[3]) : :j4

@printf("CUDA_device=%s\n", CUDA.name(CUDA.device()))
benchmark(n_satellites, n_times, propagator)

using Printf
using SatelliteToolbox
using SatelliteSimGPU

const GOLDEN_DIR = joinpath(@__DIR__, "golden")
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

function parse_args(args)
    length(args) in (2, 3) || error(
        "usage: julia --project=. bench_orbit.jl N NT [two_body|j2|j4]",
    )
    n_satellites = parse(Int, args[1])
    n_times = parse(Int, args[2])
    propagator = length(args) == 3 ? Symbol(args[3]) : :j4
    return n_satellites, n_times, propagator
end

n_satellites, n_times, propagator = parse_args(ARGS)
elements = orbital_elements(n_satellites, Float64)
times = collect(range(0.0, 86_400.0; length=n_times))

rotation_time = @elapsed rotations = teme_to_pef_rotations(times, Float64)
reference_time = @elapsed reference =
    GoldenOrbitReference.independent_positions(elements, times, propagator)
independent_positions_gpu(
    elements,
    times,
    rotations;
    propagator=propagator,
)
candidate_time = @elapsed candidate = independent_positions_gpu(
    elements,
    times,
    rotations;
    propagator=propagator,
)

absolute_error = maximum(abs.(candidate .- reference))
relative_error = maximum(
    abs.(candidate .- reference) ./ max.(abs.(reference), eps(Float64)),
)

@printf(
    "N=%d NT=%d propagator=%s\n",
    n_satellites,
    n_times,
    String(propagator),
)
@printf("%-28s %12s\n", "implementation", "seconds")
@printf("%-28s %12.6f\n", "cpu_reference", reference_time)
@printf("%-28s %12.6f\n", "host_rotation_precompute", rotation_time)
@printf("%-28s %12.6f\n", "independent_positions_gpu", candidate_time)
@printf("kernel_speedup=%.6f\n", reference_time / candidate_time)
@printf(
    "end_to_end_speedup=%.6f\n",
    reference_time / (rotation_time + candidate_time),
)
@printf("maximum_absolute_error_km=%.6e\n", absolute_error)
@printf("maximum_relative_error=%.6e\n", relative_error)

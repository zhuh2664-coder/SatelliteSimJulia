#!/usr/bin/env julia

# Reproducible orbit-backend performance baseline.  This is deliberately not a
# pass/fail latency gate: it records elapsed time and allocations while contract
# tests enforce numerical correctness separately.

using SatelliteSimBackends
using SatelliteSimJuliaSpaceBackend
using SatelliteSimOrbit
using SatelliteSimStubBackend
using Printf

const BENCHMARK_BACKENDS = (:native, :stub, :julia_space)
const BENCHMARK_PROPAGATOR = :two_body

function plane_count(satellites::Int)::Int
    for candidate in min(6, satellites):-1:1
        satellites % candidate == 0 && return candidate
    end
    return 1
end

function workload_matrix(; smoke::Bool=false, full::Bool=false)
    smoke && return [(6, 3)]
    full && return [(1, 2), (12, 60), (120, 360)]
    return [(6, 3), (24, 60)]
end

function propagate_case(name::Symbol, elements, times)
    name === :native && return propagate_to_ecef(
        elements, times; propagator=BENCHMARK_PROPAGATOR,
    )
    backend = name === :julia_space ?
        create_orbit_backend(name; propagator=BENCHMARK_PROPAGATOR) : create_orbit_backend(name)
    return propagate_to_ecef(backend, elements, times)
end

function benchmark_orbit_backends(; smoke::Bool=false, full::Bool=false)
    rows = NamedTuple[]
    for (satellites, time_points) in workload_matrix(; smoke=smoke, full=full)
        planes = plane_count(satellites)
        elements = generate_walker_delta(
            T=satellites,
            P=planes,
            F=planes == 1 ? 0 : 1,
            alt_km=550.0,
            inc_deg=53.0,
        )
        times = collect(range(0.0; step=10.0, length=time_points))
        native_reference = propagate_case(:native, elements, times)

        for backend in BENCHMARK_BACKENDS
            # One warm-up keeps compilation from dominating the recorded sample.
            propagate_case(backend, elements, times)
            GC.gc()
            sample = @timed propagate_case(backend, elements, times)
            positions = sample.value
            max_error_km = backend === :julia_space ?
                maximum(abs.(positions .- native_reference)) : missing
            push!(rows, (
                backend=backend,
                propagator=BENCHMARK_PROPAGATOR,
                satellites=satellites,
                time_points=time_points,
                elapsed_s=sample.time,
                allocated_bytes=sample.bytes,
                output_shape=size(positions),
                max_error_vs_native_km=max_error_km,
            ))
        end
    end
    return rows
end

function print_csv(rows)
    println("backend,propagator,satellites,time_points,elapsed_s,allocated_bytes,output_shape,max_error_vs_native_km")
    for row in rows
        error_text = ismissing(row.max_error_vs_native_km) ? "NA" :
            @sprintf("%.12g", row.max_error_vs_native_km)
        @printf(
            "%s,%s,%d,%d,%.9f,%d,%dx%dx%d,%s\n",
            row.backend,
            row.propagator,
            row.satellites,
            row.time_points,
            row.elapsed_s,
            row.allocated_bytes,
            row.output_shape...,
            error_text,
        )
    end
end

function main(args=ARGS)
    smoke = "--smoke" in args
    full = "--full" in args || get(ENV, "SATSIM_BENCH_FULL", "0") == "1"
    rows = benchmark_orbit_backends(; smoke=smoke, full=full)
    print_csv(rows)
    all(row -> row.output_shape == (row.satellites, row.time_points, 3), rows) || return 1
    all(row -> row.backend !== :julia_space || row.max_error_vs_native_km <= 1e-3, rows) || return 1
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end

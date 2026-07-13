#!/usr/bin/env julia
# Unified verification runner for SatelliteSimJulia.
#
# Default: architecture gates + main simulation chain + Lab + PlatformRunner + offline backends.
# Optional flags:
#   SATSIM_TEST_ONLY=boundary,lab,...  Run only selected targets
#   SATSIM_RUN_OPTIONAL=1             Run Opt and Security package tests
#   SATSIM_RUN_VIZ=1                  Instantiate/load envs/viz
#   SATSIM_RUN_GMAT=1                 Test GMAT package in envs/gmat
#   SATSIM_RUN_NIGHTLY=1              Test JuliaSpace adapter + backend integration/baseline
#   SATSIM_RUN_GPU=1                  Run Modal A10G hardware validation
#   SATSIM_GPU_TIMEOUT_SECONDS=2700   Override the Modal A10G outer timeout
#   SATSIM_VERBOSE=1                  Print a longer failure tail

using Printf

struct TestTarget
    name::String
    command::Cmd
    enabled::Bool
    reason::String
    timeout_seconds::Union{Nothing,Float64}
end

const ROOT = normpath(joinpath(@__DIR__, ".."))
const DEFAULT_GPU_TIMEOUT_SECONDS = 45 * 60.0
const PROCESS_TIMEOUT_MARKER = "PROCESS_TIMEOUT"
const PROCESS_TERMINATION_GRACE_SECONDS = 1.0
const VERBOSE = get(ENV, "SATSIM_VERBOSE", "0") == "1"
const RUN_OPTIONAL = get(ENV, "SATSIM_RUN_OPTIONAL", "0") == "1"
const RUN_VIZ = get(ENV, "SATSIM_RUN_VIZ", "0") == "1"
const RUN_GMAT = get(ENV, "SATSIM_RUN_GMAT", "0") == "1"
const RUN_NIGHTLY = get(ENV, "SATSIM_RUN_NIGHTLY", "0") == "1"
const RUN_GPU = get(ENV, "SATSIM_RUN_GPU", "0") == "1"
const ONLY_RAW = strip(get(ENV, "SATSIM_TEST_ONLY", ""))
const ONLY = isempty(ONLY_RAW) ? Set{String}() : Set(strip.(split(lowercase(ONLY_RAW), ",")))

selected(name::String) = isempty(ONLY) || lowercase(name) in ONLY

function normalize_timeout(timeout_seconds::Union{Nothing,Real})
    isnothing(timeout_seconds) && return nothing
    timeout = Float64(timeout_seconds)
    isfinite(timeout) && timeout > 0 ||
        throw(ArgumentError("timeout_seconds must be finite and positive"))
    return timeout
end

function gpu_timeout_seconds()
    raw = get(ENV, "SATSIM_GPU_TIMEOUT_SECONDS", string(DEFAULT_GPU_TIMEOUT_SECONDS))
    timeout = tryparse(Float64, raw)
    isnothing(timeout) &&
        throw(ArgumentError("SATSIM_GPU_TIMEOUT_SECONDS must be a number, got $(repr(raw))"))
    return normalize_timeout(timeout)
end

function target(
    name::String,
    command::Cmd;
    enabled::Bool=true,
    reason::String="",
    timeout_seconds::Union{Nothing,Real}=nothing,
)
    timeout = normalize_timeout(timeout_seconds)
    if !selected(name)
        return TestTarget(name, command, false, "filtered by SATSIM_TEST_ONLY", timeout)
    end
    return TestTarget(name, command, enabled, enabled ? "" : reason, timeout)
end

pkgtest(path::String) = `julia --project=$(joinpath(ROOT, path)) -e "using Pkg; Pkg.test(; coverage=false)"`

function load_smoke(project::String, package::String)
    # Optional environments may keep an ignored local Manifest.toml. Resolve it
    # before loading so newly added path dependencies do not leave the smoke
    # test using a stale dependency graph.
    code = "using Pkg; Pkg.resolve(); Pkg.instantiate(); Base.eval(Main, Meta.parse(\"using $package\"))"
    return `julia --project=$(joinpath(ROOT, project)) -e $code`
end

function build_targets()
    targets = TestTarget[]
    push!(targets, target("boundary", `julia $(joinpath(ROOT, "scripts", "check_dependency_boundaries.jl"))`))
    push!(targets, target("manifest", `julia $(joinpath(ROOT, "scripts", "check_manifest_baseline.jl"))`))
    push!(targets, target("core-smoke", `julia --project=$(joinpath(ROOT, "envs", "core")) $(joinpath(ROOT, "test", "runtests_core_smoke.jl"))`))
    push!(targets, target("bare-array", `julia --project=$(joinpath(ROOT, "envs", "core")) $(joinpath(ROOT, "test", "test_bare_array_contract.jl"))`))

    for package in ("foundation", "orbit", "link", "metrics", "net", "traffic")
        push!(targets, target(package, pkgtest(joinpath("src", package))))
    end

    root_test = addenv(
        `julia --project=$ROOT $(joinpath(ROOT, "test", "runtests.jl"))`,
        "SATSIM_RUN_CURRENT" => "1",
    )
    push!(targets, target("root", root_test))
    push!(targets, target("lab", pkgtest(joinpath("src", "lab"))))
    push!(targets, target("platform", pkgtest(joinpath("platform", "runner"))))
    push!(targets, target("backend-contract", pkgtest(joinpath("packages", "SatelliteSimBackends"))))
    push!(targets, target("gpu-contract", pkgtest(joinpath("packages", "SatelliteSimGPU"))))
    push!(targets, target(
        "gpu-a10g",
        `modal run $(joinpath(ROOT, "packages", "SatelliteSimGPU", "modal_gpu.py"))`;
        enabled=RUN_GPU,
        reason="set SATSIM_RUN_GPU=1 and configure Modal credentials",
        timeout_seconds=gpu_timeout_seconds(),
    ))
    push!(targets, target("stub-backend", pkgtest(joinpath("packages", "SatelliteSimStubBackend"))))

    push!(targets, target("opt", pkgtest(joinpath("src", "opt")); enabled=RUN_OPTIONAL, reason="set SATSIM_RUN_OPTIONAL=1"))
    push!(targets, target("security", pkgtest(joinpath("src", "security")); enabled=RUN_OPTIONAL, reason="set SATSIM_RUN_OPTIONAL=1"))
    push!(targets, target("viz", load_smoke(joinpath("envs", "viz"), "SatelliteSimViz"); enabled=RUN_VIZ, reason="set SATSIM_RUN_VIZ=1"))
    push!(targets, target("gmat", pkgtest(joinpath("src", "gmat")); enabled=RUN_GMAT, reason="set SATSIM_RUN_GMAT=1"))
    push!(targets, target("juliaspace-backend", pkgtest(joinpath("packages", "SatelliteSimJuliaSpaceBackend")); enabled=RUN_NIGHTLY, reason="set SATSIM_RUN_NIGHTLY=1"))
    backend_project = joinpath(ROOT, "envs", "backends-integration")
    backend_e2e_path = joinpath(ROOT, "test", "backends", "test_backend_end_to_end.jl")
    backend_e2e_code = "using Pkg; Pkg.resolve(); Pkg.instantiate(); include($(repr(backend_e2e_path)))"
    backend_e2e = `julia --project=$backend_project -e $backend_e2e_code`
    push!(targets, target("backend-e2e", backend_e2e; enabled=RUN_NIGHTLY, reason="set SATSIM_RUN_NIGHTLY=1"))
    backend_benchmark_path = joinpath(ROOT, "scripts", "benchmark_orbit_backends.jl")
    backend_benchmark_code = "using Pkg; Pkg.resolve(); Pkg.instantiate(); include($(repr(backend_benchmark_path))); exit(main([\"--smoke\"]))"
    backend_benchmark = `julia --project=$backend_project -e $backend_benchmark_code`
    push!(targets, target("backend-benchmark", backend_benchmark; enabled=RUN_NIGHTLY, reason="set SATSIM_RUN_NIGHTLY=1"))
    return targets
end

function kill_if_running(process::Base.Process, signal::Integer)
    process_exited(process) && return
    try
        kill(process, signal)
    catch
        process_exited(process) || rethrow()
    end
end

function terminate_process(process::Base.Process)
    kill_if_running(process, Base.SIGTERM)
    if timedwait(
        () -> process_exited(process),
        PROCESS_TERMINATION_GRACE_SECONDS;
        pollint=0.01,
    ) == :timed_out
        kill_if_running(process, Base.SIGKILL)
    end
    wait(process)
end

function timeout_marker(timeout_seconds::Float64)
    return "$PROCESS_TIMEOUT_MARKER timeout_seconds=$timeout_seconds"
end

function append_timeout_marker(output::String, timeout_seconds::Float64)
    separator = isempty(output) || endswith(output, '\n') ? "" : "\n"
    return string(output, separator, timeout_marker(timeout_seconds), '\n')
end

function run_command(
    command::Cmd;
    timeout_seconds::Union{Nothing,Real}=nothing,
)
    timeout = normalize_timeout(timeout_seconds)
    output_path = tempname()
    start_time = time()
    succeeded = false
    timed_out = false
    output = ""
    try
        open(output_path, "w") do io
            process = Base.run(pipeline(command, stdout=io, stderr=io); wait=false)
            if isnothing(timeout)
                wait(process)
            elseif timedwait(
                () -> process_exited(process),
                timeout;
                pollint=min(0.05, timeout),
            ) == :timed_out
                timed_out = true
                terminate_process(process)
            else
                wait(process)
            end
            succeeded = !timed_out && success(process)
        end
    catch
        succeeded = false
    finally
        if isfile(output_path)
            output = read(output_path, String)
            rm(output_path; force=true)
        end
    end
    if timed_out
        output = append_timeout_marker(output, timeout)
    end
    return succeeded, time() - start_time, output
end

function marker_for(output::String)
    for line in split(output, '\n')
        if occursin("tests passed", line) || occursin("Test Summary:", line) ||
           occursin("DEPENDENCY BOUNDARIES:", line) ||
           occursin("MANIFEST BASELINE:", line) ||
           occursin(r"^MODAL_GPU_VALIDATION status=PASS suite=[A-Za-z0-9_-]+$", line)
            return strip(line)
        end
    end
    return "exit 0"
end

function timeout_marker_for(output::String)
    for line in Iterators.reverse(split(output, '\n'))
        startswith(line, PROCESS_TIMEOUT_MARKER) && return line
    end
    return ""
end

function print_tail(output::String; count::Int=30)
    lines = split(output, '\n')
    for line in lines[max(1, length(lines) - count + 1):end]
        isempty(strip(line)) || println("      ", line)
    end
end

function main()
    targets = build_targets()
    results = NamedTuple[]

    println("=" ^ 92)
    println("SATELLITESIMJULIA — UNIFIED VERIFICATION")
    println("=" ^ 92)
    isempty(ONLY) || println("Filter: ", join(sort!(collect(ONLY)), ", "))

    for item in targets
        if !item.enabled
            println(rpad("[SKIP $(item.name)]", 27), item.reason)
            push!(results, (name=item.name, status="SKIP", duration=0.0, marker=item.reason))
            continue
        end

        print(rpad("[RUN $(item.name)]", 27))
        flush(stdout)
        ok, duration, output =
            run_command(item.command; timeout_seconds=item.timeout_seconds)
        if ok
            marker = marker_for(output)
            println("✓ PASS  ", @sprintf("%7.1fs", duration), "  ", marker)
            push!(results, (name=item.name, status="PASS", duration=duration, marker=marker))
        else
            marker = timeout_marker_for(output)
            println(
                "✗ FAIL  ",
                @sprintf("%7.1fs", duration),
                isempty(marker) ? "" : "  $marker",
            )
            print_tail(output; count=VERBOSE ? 100 : 30)
            push!(results, (name=item.name, status="FAIL", duration=duration, marker=marker))
        end
    end

    println("=" ^ 92)
    @printf("%-22s %-8s %-10s %s\n", "target", "status", "seconds", "marker")
    println("-" ^ 92)
    for result in results
        @printf("%-22s %-8s %-10.1f %s\n", result.name, result.status, result.duration, result.marker)
    end
    println("=" ^ 92)

    passed = count(result -> result.status == "PASS", results)
    failed = count(result -> result.status == "FAIL", results)
    skipped = count(result -> result.status == "SKIP", results)
    @printf("SUMMARY: %d passed, %d failed, %d skipped\n", passed, failed, skipped)
    return failed == 0 ? 0 : 1
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    exit(main())
end

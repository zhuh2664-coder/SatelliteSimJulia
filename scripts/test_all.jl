#!/usr/bin/env julia
# Unified verification runner for SatelliteSimJulia.
#
# Default: architecture gates + main simulation chain + Lab + offline backends.
# Optional flags:
#   SATSIM_TEST_ONLY=boundary,lab,...  Run only selected targets
#   SATSIM_RUN_OPTIONAL=1             Run Opt and Security package tests
#   SATSIM_RUN_VIZ=1                  Instantiate/load envs/viz
#   SATSIM_RUN_GMAT=1                 Test GMAT package in envs/gmat
#   SATSIM_RUN_NIGHTLY=1              Test JuliaSpace adapter + backend integration/baseline
#   SATSIM_VERBOSE=1                  Print a longer failure tail

using Printf

struct TestTarget
    name::String
    command::Cmd
    enabled::Bool
    reason::String
end

const ROOT = normpath(joinpath(@__DIR__, ".."))
const VERBOSE = get(ENV, "SATSIM_VERBOSE", "0") == "1"
const RUN_OPTIONAL = get(ENV, "SATSIM_RUN_OPTIONAL", "0") == "1"
const RUN_VIZ = get(ENV, "SATSIM_RUN_VIZ", "0") == "1"
const RUN_GMAT = get(ENV, "SATSIM_RUN_GMAT", "0") == "1"
const RUN_NIGHTLY = get(ENV, "SATSIM_RUN_NIGHTLY", "0") == "1"
const ONLY_RAW = strip(get(ENV, "SATSIM_TEST_ONLY", ""))
const ONLY = isempty(ONLY_RAW) ? Set{String}() : Set(strip.(split(lowercase(ONLY_RAW), ",")))

selected(name::String) = isempty(ONLY) || lowercase(name) in ONLY

function target(name::String, command::Cmd; enabled::Bool=true, reason::String="")
    if !selected(name)
        return TestTarget(name, command, false, "filtered by SATSIM_TEST_ONLY")
    end
    return TestTarget(name, command, enabled, enabled ? "" : reason)
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
    push!(targets, target("backend-contract", pkgtest(joinpath("packages", "SatelliteSimBackends"))))
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

function run_command(command::Cmd)
    output_path = tempname()
    start_time = time()
    success_flag = false
    output = ""
    try
        open(output_path, "w") do io
            process = run(pipeline(command, stdout=io, stderr=io); wait=true)
            success_flag = success(process)
        end
    catch
        success_flag = false
    finally
        isfile(output_path) && (output = read(output_path, String))
        isfile(output_path) && rm(output_path; force=true)
    end
    return success_flag, time() - start_time, output
end

function marker_for(output::String)
    for line in split(output, '\n')
        if occursin("tests passed", line) || occursin("Test Summary:", line) ||
           occursin("DEPENDENCY BOUNDARIES:", line) || occursin("MANIFEST BASELINE:", line)
            return strip(line)
        end
    end
    return "exit 0"
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
        ok, duration, output = run_command(item.command)
        if ok
            marker = marker_for(output)
            println("✓ PASS  ", @sprintf("%7.1fs", duration), "  ", marker)
            push!(results, (name=item.name, status="PASS", duration=duration, marker=marker))
        else
            println("✗ FAIL  ", @sprintf("%7.1fs", duration))
            print_tail(output; count=VERBOSE ? 100 : 30)
            push!(results, (name=item.name, status="FAIL", duration=duration, marker=""))
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

exit(main())

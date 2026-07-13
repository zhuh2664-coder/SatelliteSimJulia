#!/usr/bin/env julia
# Unified verification runner for SatelliteSimJulia.
#
# Default: architecture gates + main simulation chain + Lab + PlatformRunner + offline backends.
# Optional flags:
#   SATSIM_TEST_ONLY=boundary,lab,...  Run only selected targets
#   SATSIM_RUN_OPTIONAL=1             Run Opt/Security and independent AD validation
#   SATSIM_TLE_PATH=/path             Local TLE data required by ad-validation
#   SATSIM_RUN_VIZ=1                  Instantiate/load envs/viz
#   SATSIM_RUN_GMAT=1                 Test GMAT package in envs/gmat
#   SATSIM_RUN_NIGHTLY=1              Run long backend/orbit validation targets
#   SATSIM_ORBIT_TLE_PATH=/path       Add a local TLE leg to orbit-accuracy
#   SATSIM_RUN_GPU=1                  Run Modal A10G hardware validation
#   SATSIM_GPU_TIMEOUT_SECONDS=2700   Override the Modal A10G outer timeout
#   SATSIM_VERBOSE=1                  Print a longer failure tail
# CLI:
#   --list / --dry-run                List resolved targets without running them

using Printf

struct TestTarget
    name::String
    command::Cmd
    enabled::Bool
    reason::String
    timeout_seconds::Union{Nothing,Float64}
    success_marker::Union{Nothing,Regex}
end

Base.@kwdef struct RunnerConfig
    verbose::Bool = false
    run_optional::Bool = false
    run_viz::Bool = false
    run_gmat::Bool = false
    run_nightly::Bool = false
    run_gpu::Bool = false
    only::Set{String} = Set{String}()
    ad_tle_path::String = ""
end

const ROOT = normpath(joinpath(@__DIR__, ".."))
const DEFAULT_GPU_TIMEOUT_SECONDS = 45 * 60.0
const DEFAULT_PLATFORM_TIMEOUT_SECONDS = 10 * 60.0
const DEFAULT_RUNNER_SELFTEST_TIMEOUT_SECONDS = 30.0
const DEFAULT_AD_VALIDATION_TIMEOUT_SECONDS = 15 * 60.0
const DEFAULT_ORBIT_VALIDATION_TIMEOUT_SECONDS = 10 * 60.0
const PROCESS_TIMEOUT_MARKER = "PROCESS_TIMEOUT"
const MISSING_SUCCESS_MARKER = "MISSING_SUCCESS_MARKER"
const PROCESS_TERMINATION_GRACE_SECONDS = 1.0
const AD_VALIDATION_MARKER = r"^STEP1_OK$"
const ORBIT_ACCURACY_MARKER =
    r"^ORBIT_ACCURACY_VALIDATION status=PASS mode=(walker|walker-tle)-smoke rows=[1-9][0-9]*$"
const ORBIT_VALIDATION_MARKER = r"^ORBIT_VALIDATION status=PASS backend=ka_cpu$"
const RUNNER_SELFTEST_MARKER = r"^UNIFIED_RUNNER_SELFTEST status=PASS$"
const MODAL_GPU_MARKER =
    r"^MODAL_GPU_VALIDATION status=PASS suite=[A-Za-z0-9_-]+$"

function env_flag(name::String; env=ENV)
    raw = strip(get(env, name, "0"))
    raw in ("0", "1") ||
        throw(ArgumentError("$name must be 0 or 1, got $(repr(raw))"))
    return raw == "1"
end

function parse_target_filter(raw::AbstractString)
    value = strip(raw)
    isempty(value) && return Set{String}()
    names = strip.(split(lowercase(value), ","))
    any(isempty, names) &&
        throw(ArgumentError("SATSIM_TEST_ONLY contains an empty target name"))
    return Set(names)
end

function runner_config(; env=ENV)
    return RunnerConfig(
        verbose=env_flag("SATSIM_VERBOSE"; env),
        run_optional=env_flag("SATSIM_RUN_OPTIONAL"; env),
        run_viz=env_flag("SATSIM_RUN_VIZ"; env),
        run_gmat=env_flag("SATSIM_RUN_GMAT"; env),
        run_nightly=env_flag("SATSIM_RUN_NIGHTLY"; env),
        run_gpu=env_flag("SATSIM_RUN_GPU"; env),
        only=parse_target_filter(get(env, "SATSIM_TEST_ONLY", "")),
        ad_tle_path=strip(get(env, "SATSIM_TLE_PATH", "")),
    )
end

selected(name::String, only::Set{String}) = isempty(only) || lowercase(name) in only

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
    success_marker::Union{Nothing,Regex}=nothing,
)
    timeout = normalize_timeout(timeout_seconds)
    return TestTarget(
        name,
        command,
        enabled,
        enabled ? "" : reason,
        timeout,
        success_marker,
    )
end

pkgtest(path::String) = `julia --project=$(joinpath(ROOT, path)) -e "using Pkg; Pkg.test(; coverage=false)"`

function load_smoke(project::String, package::String)
    # Optional environments may keep an ignored local Manifest.toml. Resolve it
    # before loading so newly added path dependencies do not leave the smoke
    # test using a stale dependency graph.
    code = "using Pkg; Pkg.resolve(); Pkg.instantiate(); Base.eval(Main, Meta.parse(\"using $package\"))"
    return `julia --project=$(joinpath(ROOT, project)) -e $code`
end

function apply_target_filter(targets::Vector{TestTarget}, only::Set{String})
    known = Set(lowercase(item.name) for item in targets)
    unknown = sort!(collect(setdiff(only, known)))
    isempty(unknown) ||
        throw(ArgumentError("unknown SATSIM_TEST_ONLY target(s): $(join(unknown, ", "))"))
    isempty(only) && return targets

    return TestTarget[
        selected(item.name, only) ? item : TestTarget(
            item.name,
            item.command,
            false,
            "filtered by SATSIM_TEST_ONLY",
            item.timeout_seconds,
            item.success_marker,
        )
        for item in targets
    ]
end

function instantiated_include(project::String, script::String, invocation::String="")
    code = "using Pkg; Pkg.instantiate(); include($(repr(script)))"
    isempty(invocation) || (code *= "; $invocation")
    return `julia --project=$project -e $code`
end

function build_targets(config::RunnerConfig=runner_config())
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
    push!(targets, target(
        "platform",
        pkgtest(joinpath("platform", "runner"));
        timeout_seconds=DEFAULT_PLATFORM_TIMEOUT_SECONDS,
    ))
    push!(targets, target(
        "runner-timeout",
        `julia --project=$ROOT $(joinpath(ROOT, "test", "test_unified_runner_timeout.jl"))`;
        timeout_seconds=DEFAULT_RUNNER_SELFTEST_TIMEOUT_SECONDS,
        success_marker=RUNNER_SELFTEST_MARKER,
    ))
    push!(targets, target("backend-contract", pkgtest(joinpath("packages", "SatelliteSimBackends"))))
    push!(targets, target("gpu-contract", pkgtest(joinpath("packages", "SatelliteSimGPU"))))
    push!(targets, target(
        "gpu-a10g",
        `modal run $(joinpath(ROOT, "packages", "SatelliteSimGPU", "modal_gpu.py"))`;
        enabled=config.run_gpu,
        reason="set SATSIM_RUN_GPU=1 and configure Modal credentials",
        timeout_seconds=gpu_timeout_seconds(),
        success_marker=MODAL_GPU_MARKER,
    ))
    push!(targets, target("stub-backend", pkgtest(joinpath("packages", "SatelliteSimStubBackend"))))

    push!(targets, target("opt", pkgtest(joinpath("src", "opt")); enabled=config.run_optional, reason="set SATSIM_RUN_OPTIONAL=1"))
    push!(targets, target("security", pkgtest(joinpath("src", "security")); enabled=config.run_optional, reason="set SATSIM_RUN_OPTIONAL=1"))
    ad_validation = instantiated_include(
        joinpath(ROOT, "src", "opt"),
        joinpath(ROOT, "src", "opt", "scripts", "sgp4_step1_check.jl"),
    )
    ad_data_available = !isempty(config.ad_tle_path) && isfile(config.ad_tle_path)
    ad_enabled = config.run_optional && ad_data_available
    ad_reason = if !config.run_optional
        "set SATSIM_RUN_OPTIONAL=1 and SATSIM_TLE_PATH=/path/to/local.tle"
    elseif isempty(config.ad_tle_path)
        "set SATSIM_TLE_PATH=/path/to/local.tle (local TLE data required)"
    else
        "SATSIM_TLE_PATH is not a file: $(config.ad_tle_path)"
    end
    push!(targets, target(
        "ad-validation",
        ad_validation;
        enabled=ad_enabled,
        reason=ad_reason,
        timeout_seconds=DEFAULT_AD_VALIDATION_TIMEOUT_SECONDS,
        success_marker=AD_VALIDATION_MARKER,
    ))
    push!(targets, target("viz", load_smoke(joinpath("envs", "viz"), "SatelliteSimViz"); enabled=config.run_viz, reason="set SATSIM_RUN_VIZ=1"))
    push!(targets, target("gmat", pkgtest(joinpath("src", "gmat")); enabled=config.run_gmat, reason="set SATSIM_RUN_GMAT=1"))
    push!(targets, target("juliaspace-backend", pkgtest(joinpath("packages", "SatelliteSimJuliaSpaceBackend")); enabled=config.run_nightly, reason="set SATSIM_RUN_NIGHTLY=1"))
    backend_project = joinpath(ROOT, "envs", "backends-integration")
    backend_e2e_path = joinpath(ROOT, "test", "backends", "test_backend_end_to_end.jl")
    backend_e2e_code = "using Pkg; Pkg.resolve(); Pkg.instantiate(); include($(repr(backend_e2e_path)))"
    backend_e2e = `julia --project=$backend_project -e $backend_e2e_code`
    push!(targets, target("backend-e2e", backend_e2e; enabled=config.run_nightly, reason="set SATSIM_RUN_NIGHTLY=1"))
    backend_benchmark_path = joinpath(ROOT, "scripts", "benchmark_orbit_backends.jl")
    backend_benchmark_code = "using Pkg; Pkg.resolve(); Pkg.instantiate(); include($(repr(backend_benchmark_path))); exit(main([\"--smoke\"]))"
    backend_benchmark = `julia --project=$backend_project -e $backend_benchmark_code`
    push!(targets, target("backend-benchmark", backend_benchmark; enabled=config.run_nightly, reason="set SATSIM_RUN_NIGHTLY=1"))

    orbit_accuracy = instantiated_include(
        joinpath(ROOT, "src", "orbit"),
        joinpath(ROOT, "scripts", "run_orbit_accuracy_validation.jl"),
        "run_orbit_accuracy_validation()",
    )
    push!(targets, target(
        "orbit-accuracy",
        orbit_accuracy;
        enabled=config.run_nightly,
        reason="set SATSIM_RUN_NIGHTLY=1 (set SATSIM_ORBIT_TLE_PATH for the local TLE leg)",
        timeout_seconds=DEFAULT_ORBIT_VALIDATION_TIMEOUT_SECONDS,
        success_marker=ORBIT_ACCURACY_MARKER,
    ))
    orbit_validation = instantiated_include(
        joinpath(ROOT, "packages", "SatelliteSimGPU"),
        joinpath(
            ROOT,
            "packages",
            "SatelliteSimGPU",
            "test",
            "orbit_validation_regression.jl",
        ),
    )
    push!(targets, target(
        "orbit-validation",
        orbit_validation;
        enabled=config.run_nightly,
        reason="set SATSIM_RUN_NIGHTLY=1 (KernelAbstractions CPU backend; no GPU required)",
        timeout_seconds=DEFAULT_ORBIT_VALIDATION_TIMEOUT_SECONDS,
        success_marker=ORBIT_VALIDATION_MARKER,
    ))
    return apply_target_filter(targets, config.only)
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
    start_time = time_ns()
    succeeded = false
    timed_out = false
    output = ""
    execution_error = nothing
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
    catch error
        succeeded = false
        execution_error = error
    finally
        if isfile(output_path)
            output = read(output_path, String)
            rm(output_path; force=true)
        end
    end
    if timed_out
        output = append_timeout_marker(output, timeout)
    elseif !isnothing(execution_error)
        separator = isempty(output) || endswith(output, '\n') ? "" : "\n"
        output = string(
            output,
            separator,
            "PROCESS_ERROR ",
            sprint(showerror, execution_error),
            '\n',
        )
    end
    return succeeded, (time_ns() - start_time) / 1e9, output
end

const RECOGNIZED_SUCCESS_MARKERS = (
    AD_VALIDATION_MARKER,
    ORBIT_ACCURACY_MARKER,
    ORBIT_VALIDATION_MARKER,
    RUNNER_SELFTEST_MARKER,
    MODAL_GPU_MARKER,
)

clean_marker_line(line::AbstractString) =
    replace(strip(line), r"\x1b\[[0-9;]*m" => "")

function marker_matching(output::String, pattern::Regex)
    for line in split(output, '\n')
        value = clean_marker_line(line)
        occursin(pattern, value) && return value
    end
    return ""
end

function marker_for(output::String)
    for pattern in RECOGNIZED_SUCCESS_MARKERS
        marker = marker_matching(output, pattern)
        isempty(marker) || return marker
    end
    for line in split(output, '\n')
        value = clean_marker_line(line)
        if occursin("tests passed", value) || occursin("Test Summary:", value) ||
           occursin("DEPENDENCY BOUNDARIES:", value) ||
           occursin("MANIFEST BASELINE:", value)
            return value
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

function validated_outcome(
    process_succeeded::Bool,
    output::String,
    success_marker::Union{Nothing,Regex},
)
    if !process_succeeded
        return false, timeout_marker_for(output)
    end
    isnothing(success_marker) && return true, marker_for(output)

    marker = marker_matching(output, success_marker)
    isempty(marker) || return true, marker
    return false, "$MISSING_SUCCESS_MARKER pattern=$(repr(success_marker.pattern))"
end

function print_tail(output::String; count::Int=30)
    lines = split(output, '\n')
    for line in lines[max(1, length(lines) - count + 1):end]
        isempty(strip(line)) || println("      ", line)
    end
end

function command_for_display(command::Cmd)
    arguments = join(repr.(command.exec), " ")
    has_environment = !isnothing(command.env) && !isempty(command.env)
    return has_environment ? "$arguments [environment redacted]" : arguments
end

function print_target_list(io::IO, targets::Vector{TestTarget})
    println(io, "SATELLITESIMJULIA — RESOLVED TEST TARGETS")
    for item in targets
        status = item.enabled ? "RUN" : "SKIP"
        timeout = isnothing(item.timeout_seconds) ? "none" :
                  @sprintf("%.1fs", item.timeout_seconds)
        marker = isnothing(item.success_marker) ? "exit-status" :
                 item.success_marker.pattern
        @printf(
            io,
            "%-24s %-6s timeout=%-8s marker=%s\n",
            item.name,
            status,
            timeout,
            marker,
        )
        item.enabled || println(io, "  reason: ", item.reason)
        println(io, "  command: ", command_for_display(item.command))
    end
end

function cli_mode(args::Vector{String})
    isempty(args) && return :run
    length(args) == 1 ||
        throw(ArgumentError("expected at most one argument; use --list or --help"))
    args[1] in ("--list", "--dry-run") && return :list
    args[1] in ("-h", "--help") && return :help
    throw(ArgumentError("unknown argument: $(args[1])"))
end

function print_usage(io::IO=stdout)
    println(io, "usage: julia --project=. scripts/test_all.jl [--list|--dry-run]")
end

function main(args::Vector{String}=ARGS)
    mode = cli_mode(args)
    mode == :help && (print_usage(); return 0)

    config = runner_config()
    targets = build_targets(config)
    if mode == :list
        print_target_list(stdout, targets)
        return 0
    end

    results = NamedTuple[]

    println("=" ^ 92)
    println("SATELLITESIMJULIA — UNIFIED VERIFICATION")
    println("=" ^ 92)
    isempty(config.only) ||
        println("Filter: ", join(sort!(collect(config.only)), ", "))

    for item in targets
        if !item.enabled
            println(rpad("[SKIP $(item.name)]", 27), item.reason)
            push!(results, (name=item.name, status="SKIP", duration=0.0, marker=item.reason))
            continue
        end

        print(rpad("[RUN $(item.name)]", 27))
        flush(stdout)
        process_succeeded, duration, output =
            run_command(item.command; timeout_seconds=item.timeout_seconds)
        ok, marker =
            validated_outcome(process_succeeded, output, item.success_marker)
        if ok
            println("✓ PASS  ", @sprintf("%7.1fs", duration), "  ", marker)
            push!(results, (name=item.name, status="PASS", duration=duration, marker=marker))
        else
            println(
                "✗ FAIL  ",
                @sprintf("%7.1fs", duration),
                isempty(marker) ? "" : "  $marker",
            )
            print_tail(output; count=config.verbose ? 100 : 30)
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
    try
        exit(main())
    catch error
        if error isa ArgumentError
            println(stderr, "ERROR: ", sprint(showerror, error))
            exit(2)
        end
        rethrow()
    end
end

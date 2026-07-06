#!/usr/bin/env julia

# Conservative parallel validation runner.
#
# Default policy:
# - precompile first, serially, to avoid Julia cache races;
# - run lightweight validation jobs in parallel;
# - keep package/Viz/GMAT/Server groups opt-in.

using Printf

const ROOT = normpath(joinpath(@__DIR__, ".."))

_script(path...) = joinpath(ROOT, path...)

function positive_int_from_env(name::String, default::Int)
    value = get(ENV, name, string(default))
    parsed = tryparse(Int, value)
    parsed === nothing && return default
    return max(parsed, 1)
end

function enabled(name::String; default::Bool=false)
    return get(ENV, name, default ? "1" : "0") == "1"
end

const MAX_JOBS = min(positive_int_from_env("SATSIM_PARALLEL_JOBS", 3), 20)
const CHILD_THREADS = string(positive_int_from_env("SATSIM_CHILD_THREADS", 2))
const RUN_PRECOMPILE = !enabled("SATSIM_SKIP_PRECOMPILE")
const RUN_PACKAGE_TESTS = enabled("SATSIM_RUN_PACKAGE_TESTS")
const RUN_VIZ = enabled("SATSIM_RUN_VIZ_GROUP")
const RUN_GMAT = enabled("SATSIM_RUN_GMAT_GROUP")
const RUN_SERVER = enabled("SATSIM_RUN_SERVER_GROUP")

struct ValidationJob
    name::String
    cmd::Cmd
end

function job(name::String, cmd::Cmd)
    return ValidationJob(name, addenv(cmd, "JULIA_NUM_THREADS" => CHILD_THREADS))
end

function marker_for(output::String)
    checks = [
        "QUICK VALIDATE: ALL PASS",
        "SMOKE SUCCESS",
        "PROBE-2 DONE",
        "PROBE OPT: ALL PASS",
        "ORBIT PROPAGATOR MATRIX: ALL PASS",
        "ROUTING ALGORITHM MATRIX: ALL PASS",
        "TRAFFIC AON POWER: ALL PASS",
        "LAB INTEGRATION BOUNDARIES: ALL PASS",
        "AI OFFLINE REACT PLANNER: ALL PASS",
        "AI LLM PROVIDER FAKE HTTP: ALL PASS",
        "AI LLM PROVIDER TOOL LOOP: ALL PASS",
        "VIZ CZML ARTIFACT: ALL PASS",
        "DYNAMIC TOPOLOGY CHURN: ALL PASS",
        "LAB NET ROUTING VERTICAL: ALL PASS",
        "VIZ PNG ARTIFACT: ALL PASS",
        "PASS/INFO:",
        "registered experiment smoke: PASS",
        "TOPOLOGY MATRIX: ALL PASS",
        "Revise hot reload probe PASS",
        "ALL TESTS PASSED",
        "PACKAGE RESULT:",
        "tests passed",
        "Test Summary:",
    ]

    for check in checks
        for line in split(output, '\n')
            occursin(check, line) && return strip(line)
        end
    end
    return "exit 0"
end

function tail_lines(output::String; n::Int=8)
    lines = split(output, '\n')
    return [line for line in lines[max(1, length(lines) - n + 1):end] if !isempty(strip(line))]
end

function run_job(vj::ValidationJob)
    output_path = tempname()
    ok = false
    combined = ""
    elapsed = 0.0

    t0 = time()
    try
        open(output_path, "w") do io
            proc = run(pipeline(vj.cmd, stdout=io, stderr=io); wait=true)
            ok = success(proc)
        end
        combined = read(output_path, String)
    catch
        isfile(output_path) && (combined = read(output_path, String))
        ok = false
    finally
        elapsed = time() - t0
        isfile(output_path) && rm(output_path; force=true)
    end

    return (name=vj.name, ok=ok, elapsed=elapsed, marker=ok ? marker_for(combined) : "", output=combined)
end

function run_serial_stage(name::String, jobs::Vector{ValidationJob})
    isempty(jobs) && return NamedTuple[]
    println("-" ^ 88)
    println("STAGE: $name (serial)")
    println("-" ^ 88)

    results = NamedTuple[]
    for vj in jobs
        print(rpad("[RUN $(vj.name)]", 34))
        flush(stdout)
        result = run_job(vj)
        if result.ok
            println("✓ PASS  ", @sprintf("%7.1fs", result.elapsed), "  ", result.marker)
        else
            println("✗ FAIL  ", @sprintf("%7.1fs", result.elapsed))
            for line in tail_lines(result.output)
                println("      ", line)
            end
        end
        push!(results, result)
    end
    return results
end

function take_next!(next_index::Base.RefValue{Int}, lock::ReentrantLock, n::Int)
    Base.lock(lock)
    try
        idx = next_index[]
        next_index[] += 1
        return idx <= n ? idx : nothing
    finally
        Base.unlock(lock)
    end
end

function run_parallel_stage(name::String, jobs::Vector{ValidationJob})
    isempty(jobs) && return NamedTuple[]
    njobs = min(MAX_JOBS, length(jobs))
    println("-" ^ 88)
    println("STAGE: $name (parallel jobs=$njobs child_threads=$CHILD_THREADS)")
    println("-" ^ 88)

    results = Vector{Union{Nothing,NamedTuple}}(nothing, length(jobs))
    next_index = Ref(1)
    lock = ReentrantLock()
    print_lock = ReentrantLock()

    Threads.@sync begin
        for _ in 1:njobs
            Threads.@spawn begin
                while true
                    idx = take_next!(next_index, lock, length(jobs))
                    idx === nothing && break

                    vj = jobs[idx]
                    Base.lock(print_lock)
                    try
                        println(rpad("[START $(vj.name)]", 34))
                    finally
                        Base.unlock(print_lock)
                    end

                    result = run_job(vj)
                    results[idx] = result

                    Base.lock(print_lock)
                    try
                        if result.ok
                            println(rpad("[PASS $(result.name)]", 34), @sprintf("%7.1fs  %s", result.elapsed, result.marker))
                        else
                            println(rpad("[FAIL $(result.name)]", 34), @sprintf("%7.1fs", result.elapsed))
                            for line in tail_lines(result.output)
                                println("      ", line)
                            end
                        end
                    finally
                        Base.unlock(print_lock)
                    end
                end
            end
        end
    end

    return NamedTuple[result for result in results if result !== nothing]
end

function main()
    precompile_jobs = ValidationJob[]
    if RUN_PRECOMPILE
        push!(precompile_jobs, job("root_precompile", `julia --project=$ROOT -e "using Pkg; Pkg.precompile()"`))
        RUN_SERVER && push!(precompile_jobs, job("server_resolve_precompile", `julia --project=$(_script("src", "server")) -e "using Pkg; Pkg.resolve(); Pkg.precompile()"`))
    end

    core_jobs = [
        job("quick_validate", `julia --project=$ROOT $(_script("scripts", "quick_validate.jl"))`),
        job("smoke_core_net_lab", `julia --project=$ROOT $(_script("scripts", "smoke_core_net_lab_experiment.jl"))`),
        job("probe_e2e", `julia --project=$ROOT $(_script("scripts", "probe_e2e.jl"))`),
        job("probe_opt", `julia --project=$ROOT $(_script("scripts", "probe_opt.jl"))`),
        job("probe_type_stability", `julia --project=$ROOT $(_script("scripts", "probe_type_stability.jl"))`),
        job("probe_experiment_matrix", `julia --project=$ROOT $(_script("scripts", "probe_experiment_matrix.jl"))`),
        job("probe_orbit_propagator_matrix", `julia --project=$ROOT $(_script("scripts", "probe_orbit_propagator_matrix.jl"))`),
        job("probe_topology_strategy_matrix", `julia --project=$ROOT $(_script("scripts", "probe_topology_strategy_matrix.jl"))`),
        job("probe_routing_algorithm_matrix", `julia --project=$ROOT $(_script("scripts", "probe_routing_algorithm_matrix.jl"))`),
        job("probe_traffic_aon_power", `julia --project=$ROOT $(_script("scripts", "probe_traffic_aon_power.jl"))`),
        job("probe_lab_integration_boundaries", `julia --project=$ROOT $(_script("scripts", "probe_lab_integration_boundaries.jl"))`),
        job("probe_ai_offline_react_planner", `julia --project=$ROOT $(_script("scripts", "probe_ai_offline_react_planner.jl"))`),
        job("probe_ai_llm_provider_fake_http", `julia --project=$(_script("src", "lab")) $(_script("scripts", "probe_ai_llm_provider_fake_http.jl"))`),
        job("probe_ai_llm_provider_tool_loop", `julia --project=$(_script("src", "lab")) $(_script("scripts", "probe_ai_llm_provider_tool_loop.jl"))`),
        job("probe_viz_czml_artifact", `julia --project=$(_script("src", "viz")) $(_script("scripts", "probe_viz_czml_artifact.jl"))`),
        job("probe_dynamic_topology_churn", `julia --project=$ROOT $(_script("scripts", "probe_dynamic_topology_churn.jl"))`),
        job("probe_lab_net_routing_vertical", `julia --project=$ROOT $(_script("scripts", "probe_lab_net_routing_vertical.jl"))`),
        job("probe_revise_hot_reload", `julia --project=$ROOT $(_script("scripts", "probe_revise_hot_reload.jl"))`),
    ]

    package_jobs = ValidationJob[]
    if RUN_PACKAGE_TESTS
        package_cmd = addenv(
            `julia --project=$ROOT $(_script("scripts", "package_tests.jl"))`,
            "SATSIM_PACKAGE_TEST_JOBS" => get(ENV, "SATSIM_PACKAGE_TEST_JOBS", "3"),
            "SATSIM_PACKAGE_TEST_CHILD_THREADS" => get(ENV, "SATSIM_PACKAGE_TEST_CHILD_THREADS", "1"),
        )
        push!(package_jobs, ValidationJob("package_tests", package_cmd))
    end

    isolated_jobs = ValidationJob[]
    RUN_GMAT && push!(isolated_jobs, job("gmat_pkg_test", `julia --project=$ROOT -e "using Pkg; Pkg.test(\"GMAT\")"`))
    if RUN_VIZ
        push!(isolated_jobs, job("viz_png_artifact", `julia --startup-file=no --project=$(_script("src", "viz")) $(_script("scripts", "probe_viz_png_artifact.jl"))`))
        push!(isolated_jobs, job("viz_pkg_test", `julia --project=$ROOT -e "using Pkg; Pkg.test(\"SatelliteSimViz\")"`))
    end
    RUN_SERVER && push!(isolated_jobs, job("server_pkg_test", `julia --project=$(_script("src", "server")) -e "using Pkg; Pkg.test()"`))

    println("=" ^ 88)
    println("SATELLITESIMJULIA — PARALLEL VALIDATION")
    println("=" ^ 88)
    println("max_jobs=$MAX_JOBS child_threads=$CHILD_THREADS precompile=$(RUN_PRECOMPILE ? "yes" : "no")")
    println("package=$(RUN_PACKAGE_TESTS ? "yes" : "no") viz=$(RUN_VIZ ? "yes" : "no") gmat=$(RUN_GMAT ? "yes" : "no") server=$(RUN_SERVER ? "yes" : "no")")
    println("=" ^ 88)

    results = NamedTuple[]
    append!(results, run_serial_stage("precompile", precompile_jobs))
    append!(results, run_parallel_stage("core validation", core_jobs))
    append!(results, run_serial_stage("package tests", package_jobs))
    append!(results, run_serial_stage("isolated heavy/external groups", isolated_jobs))

    println("=" ^ 88)
    @printf("%-28s %-8s %-10s %s\n", "job", "status", "seconds", "marker")
    println("-" ^ 88)
    for result in results
        @printf("%-28s %-8s %-10.1f %s\n", result.name, result.ok ? "PASS" : "FAIL", result.elapsed, result.marker)
    end
    println("=" ^ 88)

    npass = count(result -> result.ok, results)
    nfail = length(results) - npass
    @printf("SUMMARY: %d passed, %d failed\n", npass, nfail)
    println("=" ^ 88)

    return nfail == 0 ? 0 : 1
end

exit(main())

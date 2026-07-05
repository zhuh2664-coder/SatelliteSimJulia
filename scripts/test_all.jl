#!/usr/bin/env julia
# Unified test runner for SatelliteSimJulia.
#
# Usage:
#   julia --project=. scripts/test_all.jl
#
# Environment variables:
#   SATSIM_TEST_ONLY=core,net,root   Run only selected targets
#   SATSIM_RUN_SLOW=1               Enable slow tests in root suite
#   SATSIM_SKIP_VIZ=1               Skip viz package
#   SATSIM_RUN_SERVER=1             Include server package tests
#   SATSIM_VERBOSE=1                Print more failure output

using Printf

struct TestTarget
    name::String
    command::Cmd
    enabled::Bool
    reason::String
end

const RUN_SERVER = get(ENV, "SATSIM_RUN_SERVER", "0") == "1"
const SKIP_VIZ = get(ENV, "SATSIM_SKIP_VIZ", "0") == "1"
const VERBOSE = get(ENV, "SATSIM_VERBOSE", "0") == "1"
const ONLY_RAW = strip(get(ENV, "SATSIM_TEST_ONLY", ""))
const ONLY = isempty(ONLY_RAW) ? Set{String}() : Set(strip.(split(lowercase(ONLY_RAW), ",")))

function selected(name::String)
    isempty(ONLY) && return true
    return lowercase(name) in ONLY
end

function target(name::String, cmd::Cmd; enabled::Bool=true, reason::String="")
    return TestTarget(name, cmd, enabled && selected(name), selected(name) ? reason : "filtered by SATSIM_TEST_ONLY")
end

function build_targets()
    targets = TestTarget[]
    push!(targets, target("root", `julia --project=. test/runtests_current.jl`))

    # Packages with Project.toml [extras]/[targets] and test/runtests.jl.
    for (short, pkg) in [
        ("foundation", "SatelliteSimFoundation"),
        ("orbit", "SatelliteSimOrbit"),
        ("metrics", "SatelliteSimMetrics"),
        ("link", "SatelliteSimLink"),
        ("gmat", "GMAT"),
        ("core", "SatelliteSimCore"),
        ("net", "SatelliteSimNet"),
        ("traffic", "SatelliteSimTraffic"),
        ("lab", "SatelliteSimLab"),
        ("opt", "SatelliteSimOpt"),
        ("distributed", "SatelliteSimDistributed"),
        ("security", "SatelliteSimSecurity"),
    ]
        push!(targets, target(short, `julia --project=. -e "using Pkg; Pkg.test(\"$pkg\")"`))
    end

    push!(targets, target("viz", `julia --project=. -e "using Pkg; Pkg.test(\"SatelliteSimViz\")"`; enabled=!SKIP_VIZ, reason="SATSIM_SKIP_VIZ=1"))
    push!(targets, target("server", `julia --project=. -e "using Pkg; Pkg.test(\"SatelliteSimServer\")"`; enabled=RUN_SERVER, reason="set SATSIM_RUN_SERVER=1"))

    # Build helper package; not a regular test target yet.
    push!(targets, target("sysimage", `true`; enabled=false, reason="no independent [extras]/[targets] test configured yet"))
    return targets
end

function run_command(cmd::Cmd)
    output_path = tempname()
    ok = false
    combined = ""
    t0 = time()
    try
        open(output_path, "w") do io
            proc = run(pipeline(cmd, stdout=io, stderr=io); wait=true)
            ok = success(proc)
        end
        combined = read(output_path, String)
    catch
        isfile(output_path) && (combined = read(output_path, String))
        ok = false
    finally
        isfile(output_path) && rm(output_path; force=true)
    end
    return ok, time() - t0, combined
end

function marker_for(output::String)
    checks = [
        "tests passed",
        "Test Summary:",
        "SatelliteSimJulia current test suite",
        "PACKAGE RESULT:",
        "RESULT:",
    ]
    for line in split(output, '\n')
        for c in checks
            occursin(c, line) && return strip(line)
        end
    end
    return "exit 0"
end

function print_tail(output::String; n::Int=20)
    lines = split(output, '\n')
    start = max(1, length(lines) - n + 1)
    for line in lines[start:end]
        isempty(strip(line)) || println("      ", line)
    end
end

function main()
    targets = build_targets()
    results = NamedTuple[]

    println("=" ^ 88)
    println("SATELLITESIMJULIA — UNIFIED TEST RUNNER")
    println("=" ^ 88)
    isempty(ONLY) || println("Filter: ", join(sort(collect(ONLY)), ", "))
    println("SATSIM_RUN_SLOW=", get(ENV, "SATSIM_RUN_SLOW", "0"), "  SATSIM_SKIP_VIZ=", get(ENV, "SATSIM_SKIP_VIZ", "0"), "  SATSIM_RUN_SERVER=", get(ENV, "SATSIM_RUN_SERVER", "0"))
    println("=" ^ 88)

    for t in targets
        if !t.enabled
            println(rpad("[SKIP $(t.name)]", 24), t.reason)
            push!(results, (name=t.name, status="SKIP", duration=0.0, marker=t.reason))
            continue
        end

        print(rpad("[RUN $(t.name)]", 24))
        flush(stdout)
        ok, duration, output = run_command(t.command)
        if ok
            mark = marker_for(output)
            println("✓ PASS  ", @sprintf("%7.1fs", duration), "  ", mark)
            push!(results, (name=t.name, status="PASS", duration=duration, marker=mark))
        else
            println("✗ FAIL  ", @sprintf("%7.1fs", duration))
            print_tail(output; n=VERBOSE ? 80 : 20)
            push!(results, (name=t.name, status="FAIL", duration=duration, marker=""))
        end
    end

    println("=" ^ 88)
    @printf("%-16s %-8s %-10s %s\n", "target", "status", "seconds", "marker")
    println("-" ^ 88)
    for r in results
        @printf("%-16s %-8s %-10.1f %s\n", r.name, r.status, r.duration, r.marker)
    end
    println("=" ^ 88)

    npass = count(r -> r.status == "PASS", results)
    nfail = count(r -> r.status == "FAIL", results)
    nskip = count(r -> r.status == "SKIP", results)
    @printf("SUMMARY: %d passed, %d failed, %d skipped\n", npass, nfail, nskip)
    println("=" ^ 88)
    return nfail == 0 ? 0 : 1
end

exit(main())

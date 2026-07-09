#!/usr/bin/env julia
# Run each migrated package's own Pkg.test() entry and print a compact summary.

using Printf

const ROOT = normpath(joinpath(@__DIR__, ".."))

const PACKAGES = [
    ("Foundation", joinpath(ROOT, "src", "foundation")),
    ("Orbit", joinpath(ROOT, "src", "orbit")),
    ("Link", joinpath(ROOT, "src", "link")),
    ("Metrics", joinpath(ROOT, "src", "metrics")),
    ("Core", joinpath(ROOT, "src", "core")),
    ("Net", joinpath(ROOT, "src", "net")),
    ("Traffic", joinpath(ROOT, "src", "traffic")),
    ("Lab", joinpath(ROOT, "src", "lab")),
    ("Opt", joinpath(ROOT, "src", "opt")),
]

function positive_int_from_env(name::String, default::Int)
    value = get(ENV, name, string(default))
    parsed = tryparse(Int, value)
    parsed === nothing && return default
    return max(parsed, 1)
end

const PACKAGE_TEST_JOBS = min(
    length(PACKAGES),
    positive_int_from_env("SATSIM_PACKAGE_TEST_JOBS", Threads.nthreads()),
)
const PACKAGE_TEST_CHILD_THREADS = string(
    positive_int_from_env("SATSIM_PACKAGE_TEST_CHILD_THREADS", 1),
)

function run_package_test(name::String, project::String)
    cmd = addenv(
        `julia --project=$project -e 'using Pkg; Pkg.test()'`,
        "JULIA_NUM_THREADS" => PACKAGE_TEST_CHILD_THREADS,
    )
    output_path = tempname()
    proc_success = false
    combined = ""

    try
        open(output_path, "w") do io
            proc = run(pipeline(cmd, stdout=io, stderr=io))
            proc_success = success(proc)
        end
        combined = read(output_path, String)
    catch
        isfile(output_path) && (combined = read(output_path, String))
        proc_success = false
    finally
        isfile(output_path) && rm(output_path; force=true)
    end

    marker = ""
    for line in split(combined, '\n')
        occursin("tests passed", line) && (marker = strip(line))
        occursin("Test Summary:", line) && isempty(marker) && (marker = strip(line))
    end

    return proc_success, marker, combined
end

function run_all_package_tests()
    results = Vector{Union{Nothing,Tuple{String,Bool,String,String}}}(nothing, length(PACKAGES))
    next_index = Ref(1)
    lock = ReentrantLock()

    function take_next_index()
        Base.lock(lock)
        try
            idx = next_index[]
            next_index[] += 1
            return idx
        finally
            Base.unlock(lock)
        end
    end

    Threads.@sync begin
        for _ in 1:PACKAGE_TEST_JOBS
            Threads.@spawn begin
                while true
                    idx = take_next_index()
                    idx > length(PACKAGES) && break

                    name, project = PACKAGES[idx]
                    pass, marker, combined = run_package_test(name, project)
                    results[idx] = (name, pass, marker, combined)
                end
            end
        end
    end

    return Tuple{String,Bool,String,String}[result for result in results if result !== nothing]
end

println("=" ^ 64)
println("PACKAGE TEST SUITE — SatelliteSimJulia")
println("jobs=$PACKAGE_TEST_JOBS child_threads=$PACKAGE_TEST_CHILD_THREADS")
println("=" ^ 64)

results = Tuple{String,Bool,String}[]

for (name, pass, marker, combined) in run_all_package_tests()
    print(rpad("[pkg $name]", 28))
    flush(stdout)
    if pass
        isempty(marker) && (marker = "exit 0")
        println("✓ PASS  ($marker)")
        push!(results, (name, true, marker))
    else
        println("✗ FAIL")
        for line in split(combined, '\n')[max(1, end - 4):end]
            isempty(line) || println("      ", line)
        end
        push!(results, (name, false, ""))
    end
end

println("=" ^ 64)
npass = count(r -> r[2], results)
nfail = length(results) - npass
@printf("PACKAGE RESULT: %d/%d passed", npass, length(results))
nfail > 0 && @printf(", %d FAILED", nfail)
println()
println("=" ^ 64)

exit(nfail == 0 ? 0 : 1)

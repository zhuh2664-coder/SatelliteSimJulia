#!/usr/bin/env julia
# Quick validation - test each package independently

const ROOT = normpath(joinpath(@__DIR__, ".."))

println("Package validation:")

failures = String[]

for pkg in ["Core", "Net", "Opt", "Lab"]
    try
        project = joinpath(ROOT, "src", lowercase(pkg))
        run(`julia --project=$project -e "using SatelliteSim$pkg; println(\"  ✓ $pkg\")"`)
    catch e
        println("  ✗ $pkg failed: $e")
        push!(failures, pkg)
    end
end

println("\nIntegration test:")
try
    run(`julia --project=$ROOT $(joinpath(ROOT, "scripts", "integration_test.jl"))`)
catch e
    println("  ✗ integration_test failed: $e")
    push!(failures, "integration_test")
end

if isempty(failures)
    println("\nQUICK VALIDATE: ALL PASS")
else
    println("\nQUICK VALIDATE: FAILURES: $(join(failures, ", "))")
    exit(1)
end

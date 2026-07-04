#!/usr/bin/env julia
# Quick validation - test each package independently

println("Package validation:")

for pkg in ["Core", "Net", "Opt", "Lab"]
    try
        run(`julia --project=src/$pkg -e "using SatelliteSim$pkg; println(\"  ✓ $pkg\")"`)
    catch e
        println("  ✗ $pkg failed: $e")
    end
end

println("\nIntegration test:")
run(`julia scripts/integration_test.jl`)

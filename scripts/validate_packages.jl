#!/usr/bin/env julia
# ============================================================
# Complete Multi-Package Validation
# ============================================================
# Validates all packages compile and export expected types.
# Run this after any major refactoring.

using Pkg

println("=" ^ 70)
println("SATELLITESIMJULIA — MULTI-PACKAGE VALIDATION")
println("=" ^ 70)

const EXPECTED_EXPORTS = Dict(
    "SatelliteSimCore" => [
        "Satellite", "GroundStation", "UserTerminal",
        "DesignOrbitElementSet", "TLEOrbitElementSet",
        "WalkerConstellationConfig", "TwoBodyPropagator",
        "PhysicalConstraints", "LEO_DEFAULTS",
        "evaluate_isl_batch", "evaluate_gsl_batch",
        "propagate_to_ecef", "generate_walker_delta"
    ],
    "SatelliteSimNet" => [
        "GridPlusStrategy", "TShapeStrategy",
        "DijkstraRouting", "RoutingGraph",
        "AccessDecisionTable", "RoutePath",
        "generate_topology", "route"
    ],
    "SatelliteSimOpt" => [
        "constellation_gradient", "propagate_with_gradient",
        "end_to_end_gradient_report",
        "create_pinn_model", "fit_pinn_routing"
    ],
    "SatelliteSimLab" => [
        "ExperimentConfig", "ExperimentState", "ExperimentResult",
        "CoverageStudy", "ConstellationStudy", "CapacityStudy",
        "run_experiment", "sweep",
        "StudyPlan", "Questionnaire"
    ]
)

all_passed = true

for (pkg_name, expected_exports) in EXPECTED_EXPORTS
    println("\n[$pkg_name]")

    try
        # Activate and load package
        Pkg.activate("src/" * lowercase(pkg_name[13:end]))  # Strip "SatelliteSim" prefix
        eval(Meta.parse("using $pkg_name"))

        # Get module
        mod = getfield(Main, Symbol(pkg_name))
        exported = names(mod, all=false, imported=false)

        # Check expected exports
        missing = String[]
        for exp in expected_exports
            if !(Symbol(exp) in exported)
                push!(missing, exp)
            end
        end

        if isempty(missing)
            println("  ✓ All expected exports present ($(length(expected_exports)) checked)")
            println("  ✓ Total exports: $(length(exported))")
        else
            println("  ✗ Missing exports: $(join(missing, ", "))")
            all_passed = false
        end

        # Test compilation
        println("  ✓ Package compiles successfully")

    catch e
        println("  ✗ FAILED: $e")
        all_passed = false
    end
end

println("\n" * "=" ^ 70)
if all_passed
    println("✅ ALL PACKAGES VALIDATED")
    println("=" ^ 70)
    println("\nAll core packages (Core, Net, Opt, Lab) are functional.")
    println("Integration test: julia scripts/integration_test.jl")
    exit(0)
else
    println("❌ VALIDATION FAILED")
    println("=" ^ 70)
    exit(1)
end

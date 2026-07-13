#!/usr/bin/env julia

include(joinpath(@__DIR__, "orbit_accuracy_harness.jl"))

function orbit_accuracy_validation_args(directory::String)
    csv_path = joinpath(directory, "orbit_accuracy_results.csv")
    report_path = joinpath(directory, "orbit_accuracy_report.md")
    args = [
        "--walker-T=6",
        "--walker-P=2",
        "--walker-F=1",
        "--dt-s=600",
        "--horizons-h=1,6",
        "--n-tle=3",
        "--tle-stride=1",
        "--out-csv=$csv_path",
        "--out-md=$report_path",
    ]

    tle_path = strip(get(ENV, "SATSIM_ORBIT_TLE_PATH", ""))
    if isempty(tle_path)
        push!(args, "--skip-tle")
        return args, "walker-smoke", csv_path, report_path
    end

    isfile(tle_path) ||
        throw(ArgumentError("SATSIM_ORBIT_TLE_PATH is not a file: $tle_path"))
    push!(args, "--tle-path=$(abspath(tle_path))")
    return args, "walker-tle-smoke", csv_path, report_path
end

function validate_orbit_accuracy_artifacts(
    rows,
    mode::String,
    csv_path::String,
    report_path::String,
)
    isempty(rows) && error("orbit accuracy harness produced no rows")
    all(row -> all(isfinite, (
        row.rmse_km,
        row.max_km,
        row.end_rmse_km,
        row.end_max_km,
    )), rows) || error("orbit accuracy harness produced non-finite metrics")

    scenarios = String[row.scenario for row in rows]
    any(scenario -> startswith(scenario, "walker"), scenarios) ||
        error("orbit accuracy harness did not exercise the Walker leg")
    if mode == "walker-tle-smoke"
        any(scenario -> startswith(scenario, "starlink"), scenarios) ||
            error("orbit accuracy harness did not exercise the requested TLE leg")
    else
        all(scenario -> startswith(scenario, "walker"), scenarios) ||
            error("Walker-only smoke unexpectedly produced non-Walker rows")
    end

    isfile(csv_path) || error("orbit accuracy CSV was not written")
    isfile(report_path) || error("orbit accuracy report was not written")
    length(readlines(csv_path)) == length(rows) + 1 ||
        error("orbit accuracy CSV row count does not match returned results")
    report = read(report_path, String)
    occursin("v1 has no absolute truth", report) ||
        error("orbit accuracy report omitted its truth statement")
end

function run_orbit_accuracy_validation()::Nothing
    mktempdir() do directory
        args, mode, csv_path, report_path =
            orbit_accuracy_validation_args(directory)
        rows = main(args)
        validate_orbit_accuracy_artifacts(
            rows,
            mode,
            csv_path,
            report_path,
        )
        println(
            "ORBIT_ACCURACY_VALIDATION status=PASS mode=$mode rows=$(length(rows))",
        )
    end
    return nothing
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    run_orbit_accuracy_validation()
end

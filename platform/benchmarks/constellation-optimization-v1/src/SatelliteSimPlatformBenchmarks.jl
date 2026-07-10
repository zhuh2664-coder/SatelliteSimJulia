module SatelliteSimPlatformBenchmarks

using JSON
using SatelliteSimOpt

export BENCHMARK_ID,
       DEFAULT_SCENARIO_PATH,
       DEFAULT_BASELINE_PATH,
       BenchmarkContractError,
       load_scenario,
       load_baseline,
       run_constellation_benchmark,
       verify_benchmark_result,
       write_benchmark_result

"""Versioned identity for the first public, source-controlled optimization benchmark."""
const BENCHMARK_ID = "satellitesim.constellation-optimization/v1"
const BENCHMARK_VERSION = 1
const BENCHMARK_ROOT = normpath(joinpath(@__DIR__, ".."))
const DEFAULT_SCENARIO_PATH = joinpath(BENCHMARK_ROOT, "scenarios", "walker4-raan-coverage-v1.json")
const DEFAULT_BASELINE_PATH = joinpath(BENCHMARK_ROOT, "baselines", "walker4-raan-coverage-v1.json")

"""A deterministic input/output contract violation for this benchmark."""
struct BenchmarkContractError <: Exception
    message::String
end
Base.showerror(io::IO, err::BenchmarkContractError) = print(io, err.message)

function _object(value, location::String)::Dict{String,Any}
    value isa AbstractDict || throw(BenchmarkContractError("$location must be a JSON object"))
    return Dict{String,Any}(String(key) => item for (key, item) in value)
end

function _read_object(path::AbstractString, label::String)::Dict{String,Any}
    isfile(path) || throw(BenchmarkContractError("$label file does not exist: $path"))
    parsed = try
        JSON.parsefile(path)
    catch err
        throw(BenchmarkContractError("$label is not valid JSON: $(sprint(showerror, err))"))
    end
    return _object(parsed, label)
end

function _exact_keys(object::Dict{String,Any}, allowed::Vector{String}, location::String)
    actual = Set(keys(object))
    expected = Set(allowed)
    unknown = sort!(collect(setdiff(actual, expected)))
    missing = sort!(collect(setdiff(expected, actual)))
    isempty(unknown) || throw(BenchmarkContractError("$location has unknown fields: $(join(unknown, ", "))"))
    isempty(missing) || throw(BenchmarkContractError("$location is missing fields: $(join(missing, ", "))"))
    return nothing
end

function _string(object::Dict{String,Any}, key::String, location::String)::String
    value = object[key]
    value isa AbstractString || throw(BenchmarkContractError("$location.$key must be a string"))
    isempty(value) && throw(BenchmarkContractError("$location.$key must not be empty"))
    return String(value)
end

function _finite_number(value, location::String)::Float64
    value isa Real || throw(BenchmarkContractError("$location must be a finite number"))
    number = Float64(value)
    isfinite(number) || throw(BenchmarkContractError("$location must be a finite number"))
    return number
end

function _positive_number(object::Dict{String,Any}, key::String, location::String)::Float64
    number = _finite_number(object[key], "$location.$key")
    number > 0 || throw(BenchmarkContractError("$location.$key must be greater than zero"))
    return number
end

function _nonnegative_number(object::Dict{String,Any}, key::String, location::String)::Float64
    number = _finite_number(object[key], "$location.$key")
    number >= 0 || throw(BenchmarkContractError("$location.$key must be non-negative"))
    return number
end

function _positive_integer(object::Dict{String,Any}, key::String, location::String)::Int
    value = object[key]
    value isa Integer || throw(BenchmarkContractError("$location.$key must be an integer"))
    number = Int(value)
    number > 0 || throw(BenchmarkContractError("$location.$key must be greater than zero"))
    return number
end

function _number_vector(value, location::String; length::Union{Nothing,Int}=nothing)::Vector{Float64}
    value isa AbstractVector || throw(BenchmarkContractError("$location must be an array"))
    values = [_finite_number(item, "$location[$index]") for (index, item) in enumerate(value)]
    length === nothing || Base.length(values) == length ||
        throw(BenchmarkContractError("$location must contain exactly $length values"))
    return values
end

function _validate_scenario!(scenario::Dict{String,Any})
    _exact_keys(scenario, ["benchmark_id", "scenario_id", "constellation", "coverage", "optimizer"], "scenario")
    _string(scenario, "benchmark_id", "scenario") == BENCHMARK_ID ||
        throw(BenchmarkContractError("scenario.benchmark_id must equal $BENCHMARK_ID"))
    _string(scenario, "scenario_id", "scenario") == "walker4-raan-coverage-v1" ||
        throw(BenchmarkContractError("scenario.scenario_id is not a supported v1 scenario"))

    constellation = _object(scenario["constellation"], "scenario.constellation")
    _exact_keys(constellation, ["planes", "satellites_per_plane", "phasing", "altitude_km", "inclination_deg"], "scenario.constellation")
    planes = _positive_integer(constellation, "planes", "scenario.constellation")
    satellites_per_plane = _positive_integer(constellation, "satellites_per_plane", "scenario.constellation")
    _positive_integer(constellation, "phasing", "scenario.constellation")
    planes == 2 && satellites_per_plane == 2 ||
        throw(BenchmarkContractError("v1 scenario fixes a 2×2 Walker constellation"))
    _positive_number(constellation, "altitude_km", "scenario.constellation")
    inclination = _finite_number(constellation["inclination_deg"], "scenario.constellation.inclination_deg")
    0 < inclination < 180 || throw(BenchmarkContractError("scenario.constellation.inclination_deg must be in (0, 180)"))

    coverage = _object(scenario["coverage"], "scenario.coverage")
    _exact_keys(coverage, ["ground_latitudes", "ground_longitudes", "times_s", "minimum_elevation_deg", "softness_deg", "target_coverage_depth"], "scenario.coverage")
    _positive_integer(coverage, "ground_latitudes", "scenario.coverage") == 3 ||
        throw(BenchmarkContractError("v1 scenario fixes three ground latitude samples"))
    _positive_integer(coverage, "ground_longitudes", "scenario.coverage") == 4 ||
        throw(BenchmarkContractError("v1 scenario fixes four ground longitude samples"))
    times = _number_vector(coverage["times_s"], "scenario.coverage.times_s"; length=3)
    times == sort(times) && length(unique(times)) == length(times) ||
        throw(BenchmarkContractError("scenario.coverage.times_s must be strictly increasing"))
    _positive_number(coverage, "minimum_elevation_deg", "scenario.coverage")
    _positive_number(coverage, "softness_deg", "scenario.coverage")
    _positive_number(coverage, "target_coverage_depth", "scenario.coverage")

    optimizer = _object(scenario["optimizer"], "scenario.optimizer")
    _exact_keys(optimizer, ["name", "steps", "learning_rate"], "scenario.optimizer")
    _string(optimizer, "name", "scenario.optimizer") == "adam-enzyme" ||
        throw(BenchmarkContractError("scenario.optimizer.name must equal adam-enzyme"))
    _positive_integer(optimizer, "steps", "scenario.optimizer") == 3 ||
        throw(BenchmarkContractError("v1 scenario fixes exactly three optimizer steps"))
    _positive_number(optimizer, "learning_rate", "scenario.optimizer") == 0.1 ||
        throw(BenchmarkContractError("v1 scenario fixes learning_rate = 0.1"))
    return scenario
end

function _validate_baseline!(baseline::Dict{String,Any})
    _exact_keys(baseline, ["benchmark_id", "baseline_version", "scenario_id", "numerical_reference", "tolerances", "requirements"], "baseline")
    _string(baseline, "benchmark_id", "baseline") == BENCHMARK_ID ||
        throw(BenchmarkContractError("baseline.benchmark_id must equal $BENCHMARK_ID"))
    baseline["baseline_version"] isa Integer && Int(baseline["baseline_version"]) == 1 ||
        throw(BenchmarkContractError("baseline.baseline_version must equal 1"))
    _string(baseline, "scenario_id", "baseline") == "walker4-raan-coverage-v1" ||
        throw(BenchmarkContractError("baseline.scenario_id is not a supported v1 scenario"))

    reference = _object(baseline["numerical_reference"], "baseline.numerical_reference")
    _exact_keys(reference, ["initial_loss", "final_loss", "improvement_percent", "final_parameters_deg", "trace_loss"], "baseline.numerical_reference")
    _finite_number(reference["initial_loss"], "baseline.numerical_reference.initial_loss")
    _finite_number(reference["final_loss"], "baseline.numerical_reference.final_loss")
    _finite_number(reference["improvement_percent"], "baseline.numerical_reference.improvement_percent")
    _number_vector(reference["final_parameters_deg"], "baseline.numerical_reference.final_parameters_deg"; length=2)
    _number_vector(reference["trace_loss"], "baseline.numerical_reference.trace_loss"; length=3)

    tolerances = _object(baseline["tolerances"], "baseline.tolerances")
    _exact_keys(tolerances, ["initial_loss_abs", "final_loss_abs", "improvement_percent_abs", "final_parameters_deg_abs", "trace_loss_abs"], "baseline.tolerances")
    for key in keys(tolerances)
        _positive_number(tolerances, key, "baseline.tolerances")
    end

    requirements = _object(baseline["requirements"], "baseline.requirements")
    _exact_keys(requirements, ["minimum_improvement_percent"], "baseline.requirements")
    _nonnegative_number(requirements, "minimum_improvement_percent", "baseline.requirements")
    return baseline
end

"""Load and strictly validate the sole source-controlled v1 benchmark scenario."""
function load_scenario(path::AbstractString=DEFAULT_SCENARIO_PATH)::Dict{String,Any}
    scenario = _read_object(path, "scenario")
    return _validate_scenario!(scenario)
end

"""Load and strictly validate the numerical reference and tolerance contract."""
function load_baseline(path::AbstractString=DEFAULT_BASELINE_PATH)::Dict{String,Any}
    baseline = _read_object(path, "baseline")
    return _validate_baseline!(baseline)
end

"""
    run_constellation_benchmark(; scenario_path=DEFAULT_SCENARIO_PATH) -> Dict

Run the fixed, deterministic v1 Walker-4 RAAN coverage optimization benchmark.
Timing is recorded for observability only and deliberately excluded from baseline
acceptance because compilation and hardware vary across independent runners.
"""
function run_constellation_benchmark(; scenario_path::AbstractString=DEFAULT_SCENARIO_PATH)::Dict{String,Any}
    scenario = load_scenario(scenario_path)
    constellation = _object(scenario["constellation"], "scenario.constellation")
    coverage = _object(scenario["coverage"], "scenario.coverage")
    optimizer = _object(scenario["optimizer"], "scenario.optimizer")

    planes = Int(constellation["planes"])
    satellites_per_plane = Int(constellation["satellites_per_plane"])
    phasing = Int(constellation["phasing"])
    altitude_km = Float64(constellation["altitude_km"])
    inclination_deg = Float64(constellation["inclination_deg"])
    ground_latitudes = Int(coverage["ground_latitudes"])
    ground_longitudes = Int(coverage["ground_longitudes"])
    times_s = _number_vector(coverage["times_s"], "scenario.coverage.times_s")
    minimum_elevation_deg = Float64(coverage["minimum_elevation_deg"])
    softness_deg = Float64(coverage["softness_deg"])
    target_coverage_depth = Float64(coverage["target_coverage_depth"])
    steps = Int(optimizer["steps"])
    learning_rate = Float64(optimizer["learning_rate"])

    initial_parameters_deg = walker_raans(planes)
    mean_anomalies_deg = walker_mas(planes, satellites_per_plane, phasing)
    ground_points, ground_weights = ground_grid(ground_latitudes, ground_longitudes)
    loss_fn = parameters_deg -> coverage_depth_loss(
        parameters_deg,
        mean_anomalies_deg,
        deg2rad(inclination_deg),
        altitude_km,
        ground_points,
        ground_weights,
        times_s;
        min_el=minimum_elevation_deg,
        τ_cov=softness_deg,
        target_K=target_coverage_depth,
    )

    initial_loss = Float64(loss_fn(initial_parameters_deg))
    started_ns = time_ns()
    final_parameters_deg, report = optimize_coverage(
        loss_fn,
        initial_parameters_deg;
        n_steps=steps,
        lr=learning_rate,
    )
    elapsed_s = (time_ns() - started_ns) / 1.0e9
    final_loss = Float64(loss_fn(final_parameters_deg))
    improvement_percent = (initial_loss - final_loss) / abs(initial_loss) * 100
    trace_loss = [Float64(item[2]) for item in report.loss_history]

    return Dict{String,Any}(
        "benchmark_id" => BENCHMARK_ID,
        "benchmark_version" => BENCHMARK_VERSION,
        "scenario_id" => String(scenario["scenario_id"]),
        "optimizer" => Dict("name" => String(optimizer["name"]), "steps" => steps, "learning_rate" => learning_rate),
        "dimensions" => Dict(
            "satellite_count" => planes * satellites_per_plane,
            "ground_point_count" => size(ground_points, 1),
            "time_step_count" => length(times_s),
            "optimized_parameter_count" => length(final_parameters_deg),
        ),
        "measurements" => Dict(
            "initial_loss" => initial_loss,
            "final_loss" => final_loss,
            "improvement_percent" => improvement_percent,
            "final_parameters_deg" => Float64.(final_parameters_deg),
            "trace_loss" => trace_loss,
            "final_gradient_norm" => Float64(report.final_gradient_norm),
        ),
        "timing" => Dict(
            "elapsed_s" => elapsed_s,
            "comparison_policy" => "record_only_not_a_pass_fail_threshold",
        ),
    )
end

function _result_object(result, key::String)::Dict{String,Any}
    result isa AbstractDict || throw(BenchmarkContractError("benchmark result must be a JSON object"))
    object = Dict{String,Any}(String(name) => value for (name, value) in result)
    haskey(object, key) || throw(BenchmarkContractError("benchmark result is missing $key"))
    return _object(object[key], "benchmark result.$key")
end

function _within(actual::Float64, expected::Float64, tolerance::Float64, field::String)
    abs(actual - expected) <= tolerance || throw(BenchmarkContractError(
        "$field drifted: actual=$actual expected=$expected tolerance=$tolerance",
    ))
    return nothing
end

"""
    verify_benchmark_result(result; baseline_path=DEFAULT_BASELINE_PATH) -> true

Independently validate result structure, the fixed v1 dimensions, numerical
reference tolerances, and the non-trivial improvement requirement. Runtime is
intentionally not compared across machines.
"""
function verify_benchmark_result(result; baseline_path::AbstractString=DEFAULT_BASELINE_PATH)::Bool
    result isa AbstractDict || throw(BenchmarkContractError("benchmark result must be a JSON object"))
    object = Dict{String,Any}(String(key) => value for (key, value) in result)
    _exact_keys(object, ["benchmark_id", "benchmark_version", "scenario_id", "optimizer", "dimensions", "measurements", "timing"], "benchmark result")
    _string(object, "benchmark_id", "benchmark result") == BENCHMARK_ID ||
        throw(BenchmarkContractError("benchmark result has an unexpected benchmark_id"))
    object["benchmark_version"] isa Integer && Int(object["benchmark_version"]) == BENCHMARK_VERSION ||
        throw(BenchmarkContractError("benchmark result has an unexpected benchmark_version"))
    _string(object, "scenario_id", "benchmark result") == "walker4-raan-coverage-v1" ||
        throw(BenchmarkContractError("benchmark result has an unexpected scenario_id"))

    optimizer = _result_object(object, "optimizer")
    _exact_keys(optimizer, ["name", "steps", "learning_rate"], "benchmark result.optimizer")
    _string(optimizer, "name", "benchmark result.optimizer") == "adam-enzyme" ||
        throw(BenchmarkContractError("benchmark result.optimizer.name is invalid"))
    _positive_integer(optimizer, "steps", "benchmark result.optimizer") == 3 ||
        throw(BenchmarkContractError("benchmark result.optimizer.steps is invalid"))
    _positive_number(optimizer, "learning_rate", "benchmark result.optimizer") == 0.1 ||
        throw(BenchmarkContractError("benchmark result.optimizer.learning_rate is invalid"))

    dimensions = _result_object(object, "dimensions")
    _exact_keys(dimensions, ["satellite_count", "ground_point_count", "time_step_count", "optimized_parameter_count"], "benchmark result.dimensions")
    dimensions["satellite_count"] == 4 || throw(BenchmarkContractError("benchmark result must contain four satellites"))
    dimensions["ground_point_count"] == 12 || throw(BenchmarkContractError("benchmark result must contain twelve ground points"))
    dimensions["time_step_count"] == 3 || throw(BenchmarkContractError("benchmark result must contain three time samples"))
    dimensions["optimized_parameter_count"] == 2 || throw(BenchmarkContractError("benchmark result must optimize two parameters"))

    measurements = _result_object(object, "measurements")
    _exact_keys(measurements, ["initial_loss", "final_loss", "improvement_percent", "final_parameters_deg", "trace_loss", "final_gradient_norm"], "benchmark result.measurements")
    initial_loss = _finite_number(measurements["initial_loss"], "benchmark result.measurements.initial_loss")
    final_loss = _finite_number(measurements["final_loss"], "benchmark result.measurements.final_loss")
    improvement_percent = _finite_number(measurements["improvement_percent"], "benchmark result.measurements.improvement_percent")
    final_parameters = _number_vector(measurements["final_parameters_deg"], "benchmark result.measurements.final_parameters_deg"; length=2)
    trace = _number_vector(measurements["trace_loss"], "benchmark result.measurements.trace_loss"; length=3)
    _finite_number(measurements["final_gradient_norm"], "benchmark result.measurements.final_gradient_norm")
    final_loss < initial_loss || throw(BenchmarkContractError("benchmark result did not reduce the loss"))

    timing = _result_object(object, "timing")
    _exact_keys(timing, ["elapsed_s", "comparison_policy"], "benchmark result.timing")
    _nonnegative_number(timing, "elapsed_s", "benchmark result.timing")
    _string(timing, "comparison_policy", "benchmark result.timing") == "record_only_not_a_pass_fail_threshold" ||
        throw(BenchmarkContractError("benchmark result.timing.comparison_policy is invalid"))

    baseline = load_baseline(baseline_path)
    reference = _object(baseline["numerical_reference"], "baseline.numerical_reference")
    tolerances = _object(baseline["tolerances"], "baseline.tolerances")
    _within(initial_loss, _finite_number(reference["initial_loss"], "baseline.initial_loss"), _positive_number(tolerances, "initial_loss_abs", "baseline.tolerances"), "initial_loss")
    _within(final_loss, _finite_number(reference["final_loss"], "baseline.final_loss"), _positive_number(tolerances, "final_loss_abs", "baseline.tolerances"), "final_loss")
    _within(improvement_percent, _finite_number(reference["improvement_percent"], "baseline.improvement_percent"), _positive_number(tolerances, "improvement_percent_abs", "baseline.tolerances"), "improvement_percent")
    parameter_tolerance = _positive_number(tolerances, "final_parameters_deg_abs", "baseline.tolerances")
    for index in eachindex(final_parameters)
        _within(final_parameters[index], _number_vector(reference["final_parameters_deg"], "baseline.final_parameters_deg"; length=2)[index], parameter_tolerance, "final_parameters_deg[$index]")
    end
    trace_tolerance = _positive_number(tolerances, "trace_loss_abs", "baseline.tolerances")
    reference_trace = _number_vector(reference["trace_loss"], "baseline.trace_loss"; length=3)
    for index in eachindex(trace)
        _within(trace[index], reference_trace[index], trace_tolerance, "trace_loss[$index]")
    end
    improvement_percent >= _nonnegative_number(_object(baseline["requirements"], "baseline.requirements"), "minimum_improvement_percent", "baseline.requirements") ||
        throw(BenchmarkContractError("benchmark result did not meet the minimum improvement requirement"))
    return true
end

"""Write a machine-readable benchmark result; the caller owns the output location."""
function write_benchmark_result(path::AbstractString, result)
    verify_benchmark_result(result)
    parent = dirname(path)
    isempty(parent) || mkpath(parent)
    open(path, "w") do io
        JSON.print(io, result, 2)
        write(io, '\n')
    end
    return path
end

end # module

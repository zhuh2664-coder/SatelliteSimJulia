using JSON
using PlatformRunner
using SatelliteSimBackends
using SatelliteSimLab
using Test

struct PlatformPassthroughComputeBackend <: AbstractComputeBackend end
struct PlatformMismatchedMetadataBackend <: AbstractComputeBackend end
const PLATFORM_COMPUTE_CALLS = Ref(0)
const PLATFORM_COMPUTE_FACTORY_CALLS = Ref(0)

SatelliteSimBackends.compute_backend_name(::PlatformPassthroughComputeBackend) =
    "platform_passthrough"
SatelliteSimBackends.compute_backend_capabilities(::PlatformPassthroughComputeBackend) = (
    operations=(:gsl_series,),
    device=:test,
    input_residency=:host,
    output_residency=:host,
)
SatelliteSimBackends.compute_backend_name(::PlatformMismatchedMetadataBackend) =
    "platform_mismatched_metadata"
SatelliteSimBackends.compute_backend_capabilities(::PlatformMismatchedMetadataBackend) = (
    operations=(:gsl_series,),
    device=:test,
    input_residency=:host,
    output_residency=:host,
)

function SatelliteSimBackends.evaluate_gsl_series(
    ::PlatformPassthroughComputeBackend,
    positions,
    stations;
    gsl_min_elevation_deg,
    gsl_max_range_km,
)
    PLATFORM_COMPUTE_CALLS[] += 1
    result = assess_gsl_series(
        positions,
        stations,
        (
            gsl_min_elevation_deg=Float64(gsl_min_elevation_deg),
            gsl_max_range_km=Float64(gsl_max_range_km),
        );
        backend=:cpu,
    )
    result.metadata["backend"] = "platform_passthrough"
    return result
end

function SatelliteSimBackends.evaluate_gsl_series(
    ::PlatformMismatchedMetadataBackend,
    positions,
    stations;
    gsl_min_elevation_deg,
    gsl_max_range_km,
)
    return assess_gsl_series(
        positions,
        stations,
        (
            gsl_min_elevation_deg=Float64(gsl_min_elevation_deg),
            gsl_max_range_km=Float64(gsl_max_range_km),
        );
        backend=:cpu,
    )
end

const VALID_CONFIG = Dict{String,Any}(
    "schema_version" => EXPERIMENT_SCHEMA_VERSION,
    "name" => "platform-runner-smoke",
    "constellation" => Dict("T" => 4, "P" => 2, "F" => 1, "alt_km" => 550.0, "inc_deg" => 53.0),
    "propagator" => "two_body",
    "tspan" => [0.0, 60.0],
    "steps" => 2,
    "topology_strategy" => "balanced",
    "routing_algorithm" => "dijkstra",
    "traffic" => "uniform",
    "ground_pairs" => Any[],
    "random_seed" => 7,
    "alpha" => 0.5,
)

@testset "PlatformRunner configuration contract" begin
    normalised = validate_experiment_config(VALID_CONFIG)
    @test normalised["schema_version"] == EXPERIMENT_SCHEMA_VERSION
    @test normalised["orbit_backend"] === nothing
    @test normalised["gsl_backend"]["name"] == "cpu"
    @test isempty(normalised["users"])
    @test normalised["steps"] == 2
    @test normalised["constellation"]["T"] == 4
    default_config = experiment_config_from_json(VALID_CONFIG)
    @test default_config.constellation.T == 4
    @test default_config.gsl_backend.name == :cpu

    legacy_config = copy(VALID_CONFIG)
    delete!(legacy_config, "schema_version")
    @test validate_experiment_config(legacy_config)["schema_version"] ==
          EXPERIMENT_SCHEMA_VERSION

    unsupported_version = copy(VALID_CONFIG)
    unsupported_version["schema_version"] = "satellitesim.experiment/v2"
    @test_throws PlatformConfigError validate_experiment_config(unsupported_version)

    unknown = copy(VALID_CONFIG)
    unknown["raw_julia_code"] = "run()"
    @test_throws PlatformConfigError validate_experiment_config(unknown)

    unsupported_pairs = copy(VALID_CONFIG)
    unsupported_pairs["ground_pairs"] = [[1, 2]]
    pair_error = try
        validate_experiment_config(unsupported_pairs)
        nothing
    catch err
        err
    end
    @test pair_error isa PlatformConfigError
    @test pair_error isa PlatformConfigError &&
          occursin("ground_stations are not defined", sprint(showerror, pair_error))

    invalid_backend = copy(VALID_CONFIG)
    invalid_backend["orbit_backend"] = Dict("name" => "stub", "options" => Dict("bad-key" => 1))
    @test_throws PlatformConfigError validate_experiment_config(invalid_backend)

    gpu_config = copy(VALID_CONFIG)
    gpu_config["gsl_backend"] = Dict(
        "name" => "cuda",
        "options" => Dict("precision" => "float32"),
    )
    gpu_config["users"] = [Dict("id" => "probe", "lat" => 35.994, "lon" => -78.899)]
    parsed_gpu_config = experiment_config_from_json(gpu_config)
    @test parsed_gpu_config.gsl_backend.name == :cuda
    @test parsed_gpu_config.gsl_backend.options == (precision="float32",)

    gpu_without_users = copy(VALID_CONFIG)
    gpu_without_users["gsl_backend"] = "cuda"
    @test_throws PlatformConfigError validate_experiment_config(gpu_without_users)

    invalid_gsl_backend = copy(VALID_CONFIG)
    invalid_gsl_backend["gsl_backend"] = Dict(
        "name" => "cuda",
        "options" => Dict("bad-key" => 1),
    )
    @test_throws PlatformConfigError validate_experiment_config(invalid_gsl_backend)

    invalid_user = copy(VALID_CONFIG)
    invalid_user["users"] = [Dict("id" => "bad", "lat" => 91.0, "lon" => 0.0)]
    @test_throws PlatformConfigError validate_experiment_config(invalid_user)
end

@testset "PlatformRunner JSON schema alignment" begin
    schema = JSON.parsefile(joinpath(
        @__DIR__, "..", "..", "schemas", "experiment-v1.schema.json",
    ))
    @test Set(schema["required"]) == Set(["name", "constellation"])
    @test schema["properties"]["schema_version"]["default"] ==
          EXPERIMENT_SCHEMA_VERSION
    @test schema["properties"]["ground_pairs"]["maxItems"] == 0

    option_name_pattern = "^[A-Za-z][A-Za-z0-9_]*\$"
    for backend in ("orbit_backend", "gsl_backend")
        object_schema = schema["properties"][backend]["oneOf"][3]
        @test object_schema["properties"]["options"]["propertyNames"]["pattern"] ==
              option_name_pattern
    end
end

@testset "PlatformRunner versioned example" begin
    example = JSON.parsefile(joinpath(@__DIR__, "..", "..", "examples", "walker8-local-v1.json"))
    normalised = validate_experiment_config(example)
    config = experiment_config_from_json(normalised)
    @test normalised["schema_version"] == EXPERIMENT_SCHEMA_VERSION
    @test config.constellation.T == 8
    @test config.constellation.P == 2
end

@testset "PlatformRunner reproducibility artifacts" begin
    mktempdir() do directory
        run = run_platform_experiment(VALID_CONFIG; output_dir=directory)
        @test run["result"]["fitness"] isa Real
        @test isfile(joinpath(directory, "result.json"))
        @test isfile(joinpath(directory, "config.snapshot.json"))
        @test isfile(joinpath(directory, "run_metadata.json"))
        @test isfile(joinpath(directory, "artifacts.index.json"))

        metadata = JSON.parsefile(joinpath(directory, "run_metadata.json"))
        @test metadata["schema_version"] == EXPERIMENT_SCHEMA_VERSION
        @test metadata["input_config_sha256"] isa String
        @test length(metadata["input_config_sha256"]) == 64
        @test metadata["gsl_backend"]["name"] == "cpu"
        @test metadata["resolved_gsl_backend"]["device"] == "cpu"
        @test metadata["resolved_gsl_backend"]["precision"] == "Float64"
        @test metadata["resolved_gsl_backend"]["call_count"] > 0

        artifacts = JSON.parsefile(joinpath(directory, "artifacts.index.json"))["artifacts"]
        @test Set(item["name"] for item in artifacts) == Set([
            "config.snapshot.json", "result.json", "run_metadata.json",
        ])
        @test_throws ArgumentError run_platform_experiment(VALID_CONFIG; output_dir=directory)
    end
end

@testset "PlatformRunner executes selected GSL backend" begin
    gpu_config = copy(VALID_CONFIG)
    gpu_config["gsl_backend"] = "missing_gpu"
    gpu_config["users"] = [Dict("id" => "probe", "lat" => 35.994, "lon" => -78.899)]
    mktempdir() do directory
        @test_throws PlatformConfigError run_platform_experiment(
            gpu_config;
            output_dir=joinpath(directory, "missing"),
        )
        @test !isdir(joinpath(directory, "missing"))
    end

    unregister_compute_backend!(:platform_passthrough)
    register_compute_backend!(
        :platform_passthrough,
        _ -> begin
            PLATFORM_COMPUTE_FACTORY_CALLS[] += 1
            PlatformPassthroughComputeBackend()
        end,
    )
    try
        selected_config = copy(gpu_config)
        selected_config["gsl_backend"] = "platform_passthrough"
        PLATFORM_COMPUTE_CALLS[] = 0
        PLATFORM_COMPUTE_FACTORY_CALLS[] = 0
        mktempdir() do directory
            run = run_platform_experiment(selected_config; output_dir=directory)
            @test PLATFORM_COMPUTE_CALLS[] > 0
            @test PLATFORM_COMPUTE_FACTORY_CALLS[] == 1
            @test run["metadata"]["resolved_gsl_backend"]["name"] ==
                  "platform_passthrough"
            resolved = run["metadata"]["resolved_gsl_backend"]
            @test resolved["device"] == "test"
            @test resolved["precision"] == "unknown"
            @test resolved["requested_spec"]["name"] == "platform_passthrough"
            @test resolved["implementation"]["name"] == "platform_passthrough"
            @test resolved["registration_generation"] >= 1
            @test resolved["resolution_id"] >= 1
            @test resolved["call_count"] > 0
        end
    finally
        unregister_compute_backend!(:platform_passthrough)
    end

    unregister_compute_backend!(:platform_mismatched_metadata)
    register_compute_backend!(
        :platform_mismatched_metadata,
        _ -> PlatformMismatchedMetadataBackend(),
    )
    try
        mismatched_config = copy(gpu_config)
        mismatched_config["gsl_backend"] = "platform_mismatched_metadata"
        mktempdir() do directory
            output_dir = joinpath(directory, "mismatched")
            @test_throws ArgumentError run_platform_experiment(
                mismatched_config;
                output_dir=output_dir,
            )
            @test !ispath(output_dir)
        end
    finally
        unregister_compute_backend!(:platform_mismatched_metadata)
    end
end

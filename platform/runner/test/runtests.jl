using JSON
using PlatformRunner
using SatelliteSimBackends
using SatelliteSimLab
using Test

struct PlatformPassthroughComputeBackend <: AbstractComputeBackend end
struct PlatformMismatchedMetadataBackend <: AbstractComputeBackend end
struct PlatformNoGSLComputeBackend <: AbstractComputeBackend end
struct PlatformOrbitBackend <: AbstractOrbitBackend
    x_offset_km::Float64
end
struct PlatformOrbitNoECEFBackend <: AbstractOrbitBackend end
const PLATFORM_COMPUTE_CALLS = Ref(0)
const PLATFORM_COMPUTE_FACTORY_CALLS = Ref(0)
const PLATFORM_ORBIT_FACTORY_CALLS = Ref(0)

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
SatelliteSimBackends.compute_backend_name(::PlatformNoGSLComputeBackend) =
    "platform_no_gsl"
SatelliteSimBackends.compute_backend_capabilities(::PlatformNoGSLComputeBackend) = (
    operations=(:isl_series,),
    device=:test,
    input_residency=:host,
    output_residency=:host,
)
SatelliteSimBackends.backend_name(::PlatformOrbitBackend) = "platform_orbit"
SatelliteSimBackends.backend_capabilities(::PlatformOrbitBackend) =
    (frames=(:ecef,), deterministic=true)
SatelliteSimBackends.backend_name(::PlatformOrbitNoECEFBackend) = "platform_orbit_no_ecef"
SatelliteSimBackends.backend_capabilities(::PlatformOrbitNoECEFBackend) =
    (frames=(:teme,), deterministic=true)

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

function SatelliteSimBackends.propagate_orbit(
    backend::PlatformOrbitBackend, elements, tspan; kwargs...
)
    times = Float64.(collect(tspan))
    n_satellites = length(elements)
    positions = Array{Float64,3}(undef, n_satellites, length(times), 3)
    for sat in 1:n_satellites, (time_index, elapsed_s) in pairs(times)
        positions[sat, time_index, 1] = 7000.0 + backend.x_offset_km + 0.001 * elapsed_s
        positions[sat, time_index, 2] = Float64(sat)
        positions[sat, time_index, 3] = 0.0
    end
    return validate_orbit_result(
        OrbitResult(positions, Dict{String,Any}(
            "backend" => "platform_orbit",
            "frame" => "ecef",
        ));
        expected_satellites=n_satellites,
        expected_times=length(times),
    )
end

function SatelliteSimBackends.propagate_orbit(
    ::PlatformOrbitNoECEFBackend, elements, tspan; kwargs...
)
    throw(ArgumentError("platform_orbit_no_ecef cannot propagate"))
end

"""Expected orbit factory invocations for one PlatformRunner run on this base."""
function expected_orbit_factory_calls()
    # Lab resolve-once pass-through → single factory call.
    if isdefined(SatelliteSimLab, :_resolve_experiment_orbit_backend)
        return 1
    end
    # Backends resolve API without Lab pass-through still creates again in Lab.
    if isdefined(SatelliteSimBackends, :resolve_orbit_backend)
        return 2
    end
    # Base e605e6a: Platform preflight create + Lab create during propagate.
    return 2
end

function assert_no_platform_artifacts(output_dir::AbstractString)
    if !ispath(output_dir)
        return true
    end
    @test isdir(output_dir)
    @test isempty(readdir(output_dir))
    return true
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

    endpoints_config = copy(VALID_CONFIG)
    endpoints_config["ground_endpoints"] = [
        Dict("id" => "durham", "lat" => 35.9940, "lon" => -78.8986),
    ]
    normalised_endpoints = validate_experiment_config(endpoints_config)
    @test length(normalised_endpoints["ground_endpoints"]) == 1
    @test normalised_endpoints["ground_endpoints"][1]["id"] == "durham"
    parsed_endpoints = experiment_config_from_json(endpoints_config)
    @test length(parsed_endpoints.ground_endpoints) == 1
    @test parsed_endpoints.ground_endpoints[1].id == "durham"

    duplicate_ids = copy(VALID_CONFIG)
    duplicate_ids["users"] = [Dict("id" => "probe", "lat" => 35.0, "lon" => -78.0)]
    duplicate_ids["ground_endpoints"] = [Dict("id" => "probe", "lat" => 36.0, "lon" => -79.0)]
    @test_throws PlatformConfigError validate_experiment_config(duplicate_ids)

    invalid_pair_index = copy(VALID_CONFIG)
    invalid_pair_index["ground_endpoints"] = [Dict("id" => "a", "lat" => 0.0, "lon" => 0.0)]
    invalid_pair_index["ground_pairs"] = [[1, 2]]
    @test_throws PlatformConfigError validate_experiment_config(invalid_pair_index)

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

    gpu_without_endpoints = copy(VALID_CONFIG)
    gpu_without_endpoints["gsl_backend"] = "cuda"
    @test_throws PlatformConfigError validate_experiment_config(gpu_without_endpoints)

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
    @test !haskey(schema["properties"]["ground_pairs"], "maxItems")
    @test haskey(schema["properties"], "ground_endpoints")

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
        @test metadata["resolved_orbit_backend"]["name"] == "native"
        @test metadata["resolved_orbit_backend"]["mode"] == "native"

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
        missing = joinpath(directory, "missing")
        @test_throws PlatformConfigError run_platform_experiment(
            gpu_config;
            output_dir=missing,
        )
        assert_no_platform_artifacts(missing)
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
            assert_no_platform_artifacts(output_dir)
        end

        # Pre-existing empty directory must stay artifact-free on identity failure.
        mktempdir() do directory
            output_dir = joinpath(directory, "precreated")
            mkdir(output_dir)
            @test_throws ArgumentError run_platform_experiment(
                mismatched_config;
                output_dir=output_dir,
            )
            assert_no_platform_artifacts(output_dir)
        end
    finally
        unregister_compute_backend!(:platform_mismatched_metadata)
    end

    unregister_compute_backend!(:platform_no_gsl)
    register_compute_backend!(
        :platform_no_gsl,
        _ -> PlatformNoGSLComputeBackend(),
    )
    try
        no_gsl_config = copy(gpu_config)
        no_gsl_config["gsl_backend"] = "platform_no_gsl"
        mktempdir() do directory
            output_dir = joinpath(directory, "no-gsl")
            @test_throws PlatformConfigError run_platform_experiment(
                no_gsl_config;
                output_dir=output_dir,
            )
            assert_no_platform_artifacts(output_dir)
        end
    finally
        unregister_compute_backend!(:platform_no_gsl)
    end
end

@testset "PlatformRunner orbit backend preflight and provenance" begin
    missing_orbit = copy(VALID_CONFIG)
    missing_orbit["orbit_backend"] = "missing_orbit"
    mktempdir() do directory
        output_dir = joinpath(directory, "missing-orbit")
        err = try
            run_platform_experiment(missing_orbit; output_dir=output_dir)
            nothing
        catch thrown
            thrown
        end
        @test err isa PlatformConfigError
        @test occursin("orbit_backend", sprint(showerror, err))
        assert_no_platform_artifacts(output_dir)
    end

    unregister_orbit_backend!(:platform_orbit_boom)
    register_orbit_backend!(
        :platform_orbit_boom,
        _ -> throw(ArgumentError("boom factory")),
    )
    try
        boom_config = copy(VALID_CONFIG)
        boom_config["orbit_backend"] = "platform_orbit_boom"
        mktempdir() do directory
            output_dir = joinpath(directory, "boom")
            mkdir(output_dir)
            @test_throws PlatformConfigError run_platform_experiment(
                boom_config;
                output_dir=output_dir,
            )
            assert_no_platform_artifacts(output_dir)
        end
    finally
        unregister_orbit_backend!(:platform_orbit_boom)
    end

    unregister_orbit_backend!(:platform_orbit_no_ecef)
    register_orbit_backend!(
        :platform_orbit_no_ecef,
        _ -> PlatformOrbitNoECEFBackend(),
    )
    try
        no_ecef = copy(VALID_CONFIG)
        no_ecef["orbit_backend"] = "platform_orbit_no_ecef"
        mktempdir() do directory
            output_dir = joinpath(directory, "no-ecef")
            @test_throws PlatformConfigError run_platform_experiment(
                no_ecef;
                output_dir=output_dir,
            )
            assert_no_platform_artifacts(output_dir)
        end
    finally
        unregister_orbit_backend!(:platform_orbit_no_ecef)
    end

    unregister_orbit_backend!(:platform_orbit)
    register_orbit_backend!(
        :platform_orbit,
        options -> begin
            PLATFORM_ORBIT_FACTORY_CALLS[] += 1
            PlatformOrbitBackend(Float64(get(options, :x_offset_km, 0.0)))
        end,
    )
    try
        orbit_config = copy(VALID_CONFIG)
        orbit_config["orbit_backend"] = Dict(
            "name" => "platform_orbit",
            "options" => Dict("x_offset_km" => 1.5),
        )
        PLATFORM_ORBIT_FACTORY_CALLS[] = 0
        mktempdir() do directory
            run = run_platform_experiment(orbit_config; output_dir=directory)
            @test PLATFORM_ORBIT_FACTORY_CALLS[] == expected_orbit_factory_calls()
            resolved = run["metadata"]["resolved_orbit_backend"]
            @test resolved["name"] == "platform_orbit"
            @test resolved["mode"] == "registered"
            @test resolved["requested_spec"]["name"] == "platform_orbit"
            @test resolved["requested_spec"]["options"]["x_offset_km"] == 1.5
            @test "ecef" in resolved["capabilities"]["frames"]
            @test resolved["instance_binding"] isa String
            @test !isempty(resolved["instance_binding"])
            @test isfile(joinpath(directory, "run_metadata.json"))
        end
    finally
        unregister_orbit_backend!(:platform_orbit)
    end
end

@testset "PlatformRunner ground endpoint demand validation" begin
    negative_uplink = copy(VALID_CONFIG)
    negative_uplink["ground_endpoints"] = [
        Dict("id" => "a", "lat" => 0.0, "lon" => 0.0, "uplink_demand_mbps" => -1.0),
    ]
    @test_throws PlatformConfigError validate_experiment_config(negative_uplink)

    negative_downlink = copy(VALID_CONFIG)
    negative_downlink["ground_endpoints"] = [
        Dict("id" => "a", "lat" => 0.0, "lon" => 0.0, "downlink_demand_mbps" => -1.0),
    ]
    @test_throws PlatformConfigError validate_experiment_config(negative_downlink)

    non_numeric_demand = copy(VALID_CONFIG)
    non_numeric_demand["ground_endpoints"] = [
        Dict("id" => "a", "lat" => 0.0, "lon" => 0.0, "uplink_demand_mbps" => "fast"),
    ]
    @test_throws PlatformConfigError validate_experiment_config(non_numeric_demand)
end

@testset "PlatformRunner traffic demand propagation" begin
    traffic_config = copy(VALID_CONFIG)
    traffic_config["name"] = "platform-traffic-bridge"
    traffic_config["constellation"] = Dict("T" => 24, "P" => 6, "F" => 1, "alt_km" => 550.0, "inc_deg" => 53.0)
    traffic_config["ground_endpoints"] = [
        Dict("id" => "src", "lat" => 0.0, "lon" => 0.0, "alt_km" => 0.0, "uplink_demand_mbps" => 100.0),
        Dict("id" => "dst", "lat" => 10.0, "lon" => 10.0, "alt_km" => 0.0, "downlink_demand_mbps" => 100.0),
    ]
    traffic_config["ground_pairs"] = [[1, 2]]
    traffic_config["traffic"] = "uniform"

    mktempdir() do directory
        run = run_platform_experiment(traffic_config; output_dir=directory)
        @test run["metadata"]["ground_endpoints"] == 2
        @test run["metadata"]["ground_pairs"] == 1
        @test run["result"]["traffic_evaluation_ran"] == true
        @test run["result"]["traffic_demands"] == 1
        @test run["result"]["offered_mbps"] > 0.0
    end
end

@testset "PlatformRunner legacy users merge with ground_endpoints" begin
    merged_config = copy(VALID_CONFIG)
    merged_config["name"] = "platform-legacy-merge"
    merged_config["users"] = [
        Dict("id" => "legacy", "lat" => 35.0, "lon" => -78.0, "uplink_demand_mbps" => 10.0),
    ]
    merged_config["ground_endpoints"] = [
        Dict("id" => "new", "lat" => 36.0, "lon" => -79.0, "downlink_demand_mbps" => 20.0),
    ]
    normalised = validate_experiment_config(merged_config)
    @test length(normalised["users"]) == 1
    @test length(normalised["ground_endpoints"]) == 1
    config = experiment_config_from_json(normalised)
    @test length(config.ground_endpoints) == 2
    @test Set(ep.id for ep in config.ground_endpoints) == Set(["legacy", "new"])
    by_id = Dict(ep.id => ep for ep in config.ground_endpoints)
    @test by_id["legacy"].uplink_demand_mbps == 10.0
    @test by_id["new"].downlink_demand_mbps == 20.0
end

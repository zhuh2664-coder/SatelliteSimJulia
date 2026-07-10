using JSON
using PlatformRunner
using Test

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
    @test normalised["steps"] == 2
    @test normalised["constellation"]["T"] == 4
    @test experiment_config_from_json(VALID_CONFIG).constellation.T == 4

    unknown = copy(VALID_CONFIG)
    unknown["raw_julia_code"] = "run()"
    @test_throws PlatformConfigError validate_experiment_config(unknown)

    invalid_pair = copy(VALID_CONFIG)
    invalid_pair["ground_pairs"] = [[1, 1]]
    @test_throws PlatformConfigError validate_experiment_config(invalid_pair)

    invalid_backend = copy(VALID_CONFIG)
    invalid_backend["orbit_backend"] = Dict("name" => "stub", "options" => Dict("bad-key" => 1))
    @test_throws PlatformConfigError validate_experiment_config(invalid_backend)
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

        artifacts = JSON.parsefile(joinpath(directory, "artifacts.index.json"))["artifacts"]
        @test Set(item["name"] for item in artifacts) == Set([
            "config.snapshot.json", "result.json", "run_metadata.json",
        ])
        @test_throws ArgumentError run_platform_experiment(VALID_CONFIG; output_dir=directory)
    end
end

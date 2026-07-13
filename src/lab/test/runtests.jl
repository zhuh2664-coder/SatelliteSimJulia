using SatelliteSimCore
using SatelliteSimLab
using SatelliteSimNet
using SatelliteSimTraffic
using SatelliteSimFoundation
using SatelliteSimBackends
using JSON
using HTTP
using Printf
using Serialization
using Test

struct LabOffsetOrbitBackend <: AbstractOrbitBackend
    x_offset_km::Float64
end

SatelliteSimBackends.backend_name(::LabOffsetOrbitBackend) = "lab_offset"
SatelliteSimBackends.backend_capabilities(::LabOffsetOrbitBackend) = (
    frames=(:ecef,),
    deterministic=true,
)
SatelliteSimBackends.orbit_backend_cache_token(backend::LabOffsetOrbitBackend) =
    (x_offset_km=backend.x_offset_km,)
SatelliteSimBackends.orbit_backend_source_files(::LabOffsetOrbitBackend) =
    [@__FILE__]

function SatelliteSimBackends.propagate_orbit(
    backend::LabOffsetOrbitBackend, elements, times; kwargs...
)
    positions = propagate_to_ecef(elements, Float64.(collect(times)); propagator=:two_body)
    positions[:, :, 1] .+= backend.x_offset_km
    return OrbitResult(
        positions,
        Dict{String,Any}("backend" => "lab_offset", "frame" => "ecef"),
    )
end

struct LabCacheProbeOrbitBackend <: AbstractOrbitBackend
    instance_id::Int
    x_offset_km::Float64
end
mutable struct StatefulProbeOrbitBackend <: AbstractOrbitBackend
    value::Int
end
struct LabMismatchedOrbitBackend <: AbstractOrbitBackend end
const LAB_ORBIT_FACTORY_CALLS = Ref(0)
const LAB_ORBIT_PROPAGATION_CALLS = Ref(0)
const LAB_ORBIT_TOKEN_INSTANCE = Ref(0)
const LAB_ORBIT_PROPAGATION_INSTANCE = Ref(0)
const LAB_STATEFUL_ORBIT_PROPAGATION_CALLS = Ref(0)

SatelliteSimBackends.backend_name(::LabCacheProbeOrbitBackend) =
    "lab_cache_probe"
SatelliteSimBackends.backend_capabilities(::LabCacheProbeOrbitBackend) = (
    frames=(:ecef,),
    deterministic=true,
)
function SatelliteSimBackends.orbit_backend_cache_token(
    backend::LabCacheProbeOrbitBackend,
)
    LAB_ORBIT_TOKEN_INSTANCE[] = backend.instance_id
    return (x_offset_km=backend.x_offset_km,)
end
SatelliteSimBackends.orbit_backend_source_files(::LabCacheProbeOrbitBackend) =
    [@__FILE__]

function SatelliteSimBackends.propagate_orbit(
    backend::LabCacheProbeOrbitBackend,
    elements,
    times;
    kwargs...,
)
    LAB_ORBIT_PROPAGATION_CALLS[] += 1
    LAB_ORBIT_PROPAGATION_INSTANCE[] = backend.instance_id
    positions = propagate_to_ecef(elements, Float64.(collect(times)); propagator=:two_body)
    positions[:, :, 1] .+= backend.x_offset_km
    return OrbitResult(
        positions,
        Dict{String,Any}("backend" => "lab_cache_probe", "frame" => "ecef"),
    )
end

SatelliteSimBackends.backend_name(::StatefulProbeOrbitBackend) =
    "stateful_orbit_probe"
SatelliteSimBackends.backend_capabilities(::StatefulProbeOrbitBackend) = (
    frames=(:ecef,),
    deterministic=false,
)
SatelliteSimBackends.orbit_backend_source_files(::StatefulProbeOrbitBackend) =
    [@__FILE__]
function SatelliteSimBackends.propagate_orbit(
    backend::StatefulProbeOrbitBackend,
    elements,
    times;
    kwargs...,
)
    LAB_STATEFUL_ORBIT_PROPAGATION_CALLS[] += 1
    positions = propagate_to_ecef(elements, Float64.(collect(times)); propagator=:two_body)
    positions[:, :, 1] .+= backend.value
    backend.value += 1
    return OrbitResult(
        positions,
        Dict{String,Any}("backend" => "stateful_orbit_probe", "frame" => "ecef"),
    )
end

SatelliteSimBackends.backend_name(::LabMismatchedOrbitBackend) =
    "lab_expected_orbit"
SatelliteSimBackends.backend_capabilities(::LabMismatchedOrbitBackend) = (
    frames=(:ecef,),
    deterministic=true,
)
SatelliteSimBackends.orbit_backend_cache_token(::LabMismatchedOrbitBackend) =
    :lab_mismatched_orbit
function SatelliteSimBackends.propagate_orbit(
    ::LabMismatchedOrbitBackend,
    elements,
    times;
    kwargs...,
)
    positions = propagate_to_ecef(elements, Float64.(collect(times)); propagator=:two_body)
    return OrbitResult(
        positions,
        Dict{String,Any}("backend" => "different-orbit", "frame" => "ecef"),
    )
end

struct LabPassthroughComputeBackend <: AbstractComputeBackend end
struct LabCPUDeviceBackend <: AbstractComputeBackend end
struct LabMismatchedMetadataBackend <: AbstractComputeBackend end
struct StatefulProbeComputeBackend <: AbstractComputeBackend
    value::Int
end
const LAB_COMPUTE_CALLS = Ref(0)
const LAB_COMPUTE_FACTORY_CALLS = Ref(0)

SatelliteSimBackends.compute_backend_name(::LabPassthroughComputeBackend) =
    "lab_passthrough"
SatelliteSimBackends.compute_backend_capabilities(::LabPassthroughComputeBackend) = (
    operations=(:gsl_series,),
    device=:test,
    input_residency=:host,
    output_residency=:host,
)
SatelliteSimBackends.compute_backend_cache_token(::LabPassthroughComputeBackend) =
    :lab_passthrough
SatelliteSimBackends.compute_backend_name(::LabCPUDeviceBackend) =
    "lab_cpu_device"
SatelliteSimBackends.compute_backend_capabilities(::LabCPUDeviceBackend) = (
    operations=(:gsl_series,),
    device=:cpu,
    input_residency=:host,
    output_residency=:host,
)
SatelliteSimBackends.compute_backend_name(::LabMismatchedMetadataBackend) =
    "lab_mismatched_metadata"
SatelliteSimBackends.compute_backend_capabilities(::LabMismatchedMetadataBackend) = (
    operations=(:gsl_series,),
    device=:test,
    input_residency=:host,
    output_residency=:host,
)
SatelliteSimBackends.compute_backend_capabilities(::StatefulProbeComputeBackend) = (
    operations=(:gsl_series,),
    device=:test,
    input_residency=:host,
    output_residency=:host,
)

function SatelliteSimBackends.evaluate_gsl_series(
    ::LabPassthroughComputeBackend,
    positions,
    stations;
    gsl_min_elevation_deg,
    gsl_max_range_km,
)
    LAB_COMPUTE_CALLS[] += 1
    constraints = PhysicalConstraints(
        gsl_min_elevation_deg=Float64(gsl_min_elevation_deg),
        gsl_max_range_km=Float64(gsl_max_range_km),
    )
    result = assess_gsl_series(
        positions,
        stations,
        constraints;
        backend=:cpu,
    )
    result.metadata["backend"] = "lab_passthrough"
    return result
end

function SatelliteSimBackends.evaluate_gsl_series(
    ::LabMismatchedMetadataBackend,
    positions,
    stations;
    gsl_min_elevation_deg,
    gsl_max_range_km,
)
    return assess_gsl_series(
        positions,
        stations,
        PhysicalConstraints(
            gsl_min_elevation_deg=Float64(gsl_min_elevation_deg),
            gsl_max_range_km=Float64(gsl_max_range_km),
        );
        backend=:cpu,
    )
end

function _small_config(;
    name="lab-smoke",
    propagator=DefaultPropagator,
    orbit_backend=nothing,
    gsl_backend=nothing,
)
    return ExperimentConfig(
        name = name,
        constellation_params = Dict(
            :T => 6.0,
            :P => 3.0,
            :F => 1.0,
            :alt_km => 550.0,
            :inc_deg => 53.0,
        ),
        tspan = [0.0, 60.0],
        propagator = propagator,
        orbit_backend = orbit_backend,
        gsl_backend = gsl_backend,
        topology_strategy = GridPlusStrategy(),
        routing_algorithm = DijkstraRouting(),
        users = [
            GroundUser("beijing", 39.9042, 116.4074, 20.0, 100.0, "smoke"),
            GroundUser("singapore", 1.3521, 103.8198, 20.0, 100.0, "smoke"),
        ],
        ground_pairs = [(1, 2)],
    )
end

function _subpoint_deg(positions::Array{Float64,3}, sat_id::Int)
    x, y, z = positions[sat_id, 1, 1], positions[sat_id, 1, 2], positions[sat_id, 1, 3]
    radius = sqrt(x * x + y * y + z * z)
    return (asind(z / radius), atan(y, x) * 180 / pi)
end

function _varied_tle_text(n::Int=8)
    line1 = "1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753"
    lines = String[]
    for index in 0:n-1
        angle = 360.0 * index / n
        line2 = @sprintf(
            "2 00005  53.0000 %8.4f 0001000   0.0000 %8.4f 15.00000000000001",
            angle,
            angle,
        )
        append!(lines, ("SAT $(index + 1)", line1, line2))
    end
    return join(lines, "\n")
end

@testset "SatelliteSimLab" begin
    @testset "include order smoke" begin
        @test isdefined(SatelliteSimLab, :ExperimentConfig)
        @test isdefined(SatelliteSimLab, :ResolutionContext)
        @test isdefined(SatelliteSimLab, :TrafficResolutionContext)
        @test isdefined(SatelliteSimLab, :full_constellation_assessment)

        cfg = ExperimentConfig(name = "include-order-smoke", tspan = [0.0, 60.0])
        @test cfg.name == "include-order-smoke"
        @test cfg.tspan == [0.0, 60.0]
        @test cfg.gsl_backend == ComputeBackendSpec(:cpu)
    end

    @testset "registered orbit backend selection" begin
        @test ExperimentConfig().orbit_backend === nothing
        @test ExperimentConfig(orbit_backend=:deferred).orbit_backend == OrbitBackendSpec(:deferred)
        @test_throws ArgumentError ExperimentConfig(orbit_backend=LabOffsetOrbitBackend(1.0))

        unregister_orbit_backend!(:lab_offset)
        register_orbit_backend!(
            :lab_offset,
            options -> LabOffsetOrbitBackend(Float64(get(options, :x_offset_km, 0.0))),
        )
        try
            native_config = _small_config(;
                name="native-backend-control",
                propagator=:two_body,
            )
            backend_config = ExperimentConfig(
                name = "registered-backend",
                constellation_params = Dict(
                    :T => 6.0, :P => 3.0, :F => 1.0,
                    :alt_km => 550.0, :inc_deg => 53.0,
                ),
                tspan = [0.0, 60.0],
                propagator = :two_body,
                topology_strategy = GridPlusStrategy(),
                routing_algorithm = DijkstraRouting(),
                ground_endpoints = native_config.ground_endpoints,
                ground_pairs = native_config.ground_pairs,
                orbit_backend = OrbitBackendSpec(:lab_offset; x_offset_km=1.25),
            )

            _, native_positions = propagate_constellation_positions(native_config)
            _, backend_positions = propagate_constellation_positions(backend_config)
            @test backend_positions[:, :, 1] ≈ native_positions[:, :, 1] .+ 1.25
            @test backend_positions[:, :, 2:3] ≈ native_positions[:, :, 2:3]
            @test SatelliteSimLab.config_hash(native_config) != SatelliteSimLab.config_hash(backend_config)

            result = run_experiment(backend_config)
            @test result isa ExperimentResult
            @test result.config.orbit_backend.name == :lab_offset
        finally
            unregister_orbit_backend!(:lab_offset)
        end
    end

    @testset "resolved orbit backend cache binding" begin
        name = :lab_cache_probe
        unregister_orbit_backend!(name)
        factory = options -> begin
            LAB_ORBIT_FACTORY_CALLS[] += 1
            LabCacheProbeOrbitBackend(
                LAB_ORBIT_FACTORY_CALLS[],
                Float64(get(options, :x_offset_km, 0.0)),
            )
        end
        register_orbit_backend!(name, factory)
        try
            config = _small_config(
                name="resolved-orbit-cache-binding",
                propagator=:two_body,
                orbit_backend=OrbitBackendSpec(name; x_offset_km=2.5),
            )

            LAB_ORBIT_FACTORY_CALLS[] = 0
            first_resolution = resolve_orbit_backend(config.orbit_backend)
            first_hash = SatelliteSimLab.config_hash(
                config;
                orbit_resolution=first_resolution,
            )
            second_resolution = resolve_orbit_backend(config.orbit_backend)
            second_hash = SatelliteSimLab.config_hash(
                config;
                orbit_resolution=second_resolution,
            )
            @test LAB_ORBIT_FACTORY_CALLS[] == 2
            @test first_hash == second_hash
            @test orbit_backend_provenance(first_resolution).resolution_id !=
                  orbit_backend_provenance(second_resolution).resolution_id

            mismatched_config = _small_config(
                name="mismatched-orbit-resolution",
                propagator=:two_body,
                orbit_backend=:different_orbit_spec,
            )
            propagation_calls = LAB_ORBIT_PROPAGATION_CALLS[]
            @test_throws ArgumentError SatelliteSimLab.config_hash(
                mismatched_config;
                orbit_resolution=first_resolution,
            )
            @test_throws ArgumentError SatelliteSimLab._run_experiment(
                mismatched_config,
                first_resolution,
                resolve_compute_backend(:cpu),
            )
            @test LAB_ORBIT_PROPAGATION_CALLS[] == propagation_calls
            @test_throws ArgumentError SatelliteSimLab._run_experiment(
                config,
                nothing,
                resolve_compute_backend(:cpu),
            )

            mktempdir() do root
                cd(root) do
                    LAB_ORBIT_FACTORY_CALLS[] = 0
                    LAB_ORBIT_PROPAGATION_CALLS[] = 0
                    LAB_ORBIT_TOKEN_INSTANCE[] = 0
                    LAB_ORBIT_PROPAGATION_INSTANCE[] = 0

                    miss = cached_experiment(config)
                    @test miss isa ExperimentResult
                    @test LAB_ORBIT_FACTORY_CALLS[] == 1
                    @test LAB_ORBIT_PROPAGATION_CALLS[] == 1
                    @test LAB_ORBIT_TOKEN_INSTANCE[] == 1
                    @test LAB_ORBIT_PROPAGATION_INSTANCE[] == 1

                    hit = cached_experiment(config)
                    @test hit isa ExperimentResult
                    @test LAB_ORBIT_FACTORY_CALLS[] == 2
                    @test LAB_ORBIT_PROPAGATION_CALLS[] == 1
                    @test LAB_ORBIT_TOKEN_INSTANCE[] == 2
                    @test LAB_ORBIT_PROPAGATION_INSTANCE[] == 1

                    forced = cached_experiment(config; force=true)
                    @test forced isa ExperimentResult
                    @test LAB_ORBIT_FACTORY_CALLS[] == 3
                    @test LAB_ORBIT_PROPAGATION_CALLS[] == 2
                    @test LAB_ORBIT_TOKEN_INSTANCE[] == 3
                    @test LAB_ORBIT_PROPAGATION_INSTANCE[] == 3
                end
            end
        finally
            unregister_orbit_backend!(name)
        end
    end

    @testset "uncacheable stateful orbit backend fails closed" begin
        name = :stateful_orbit_probe
        unregister_orbit_backend!(name)
        factory_calls = Ref(0)
        register_orbit_backend!(
            name,
            _ -> begin
                factory_calls[] += 1
                StatefulProbeOrbitBackend(factory_calls[])
            end,
        )
        try
            config = _small_config(
                name="uncacheable-stateful-orbit",
                propagator=:two_body,
                orbit_backend=name,
            )
            LAB_STATEFUL_ORBIT_PROPAGATION_CALLS[] = 0
            @test run_experiment(config) isa ExperimentResult
            @test factory_calls[] == 1
            @test LAB_STATEFUL_ORBIT_PROPAGATION_CALLS[] == 1

            @test_throws ArgumentError SatelliteSimLab.config_hash(config)
            @test factory_calls[] == 2
            @test LAB_STATEFUL_ORBIT_PROPAGATION_CALLS[] == 1

            mktempdir() do root
                cd(root) do
                    @test_throws ArgumentError cached_experiment(config)
                    @test factory_calls[] == 3
                    @test LAB_STATEFUL_ORBIT_PROPAGATION_CALLS[] == 1
                    @test isempty(readdir(SatelliteSimLab._cache_dir()))
                end
            end
        finally
            unregister_orbit_backend!(name)
        end
    end

    @testset "resolved orbit metadata identity is enforced" begin
        name = :lab_mismatched_orbit
        unregister_orbit_backend!(name)
        register_orbit_backend!(name, _ -> LabMismatchedOrbitBackend())
        try
            @test_throws ArgumentError run_experiment(
                _small_config(
                    name="mismatched-orbit-metadata",
                    propagator=:two_body,
                    orbit_backend=name,
                ),
            )
        finally
            unregister_orbit_backend!(name)
        end
    end

    @testset "registered GSL compute backend selection" begin
        @test ExperimentConfig().gsl_backend == ComputeBackendSpec(:cpu)
        @test ExperimentConfig(gsl_backend=:deferred).gsl_backend ==
              ComputeBackendSpec(:deferred)
        @test study("backend-dsl"; gsl_backend=:deferred).gsl_backend ==
              ComputeBackendSpec(:deferred)
        @test_throws ArgumentError ExperimentConfig(
            gsl_backend=LabPassthroughComputeBackend(),
        )

        unregister_compute_backend!(:lab_passthrough)
        register_compute_backend!(
            :lab_passthrough,
            _ -> begin
                LAB_COMPUTE_FACTORY_CALLS[] += 1
                LabPassthroughComputeBackend()
            end,
        )
        try
            cpu_config = _small_config(name="cpu-gsl-control", gsl_backend=:cpu)
            backend_config = _small_config(
                name="registered-gsl-backend",
                gsl_backend=:lab_passthrough,
            )
            cpu_result = run_experiment(cpu_config)
            LAB_COMPUTE_CALLS[] = 0
            LAB_COMPUTE_FACTORY_CALLS[] = 0
            backend_result = run_experiment(backend_config)

            @test LAB_COMPUTE_CALLS[] > 0
            @test LAB_COMPUTE_FACTORY_CALLS[] == 1
            @test backend_result.coverage.coverage_ratio ==
                  cpu_result.coverage.coverage_ratio
            @test backend_result.fitness == cpu_result.fitness
            @test SatelliteSimLab.config_hash(cpu_config) !=
                  SatelliteSimLab.config_hash(backend_config)
            empty_config = ExperimentConfig(
                name="empty-user-gsl-backend",
                constellation=backend_config.constellation,
                propagator=backend_config.propagator,
                tspan=backend_config.tspan,
                constraints=backend_config.constraints,
                topology_strategy=backend_config.topology_strategy,
                routing_algorithm=backend_config.routing_algorithm,
                gsl_backend=:lab_passthrough,
            )
            @test_throws ArgumentError SatelliteSimLab._resolve_experiment_gsl_backend(
                empty_config,
            )
            _, empty_positions = propagate_constellation_positions(empty_config)
            LAB_COMPUTE_CALLS[] = 0
            LAB_COMPUTE_FACTORY_CALLS[] = 0
            empty_available, empty_coverage = assess_coverage(
                empty_positions,
                GroundEndpoint[],
                empty_config.constraints;
                gsl_backend=:lab_passthrough,
            )
            @test size(empty_available) == (empty_config.constellation.T, 0)
            @test empty_coverage.total_users == 0
            @test LAB_COMPUTE_CALLS[] == 1
            @test LAB_COMPUTE_FACTORY_CALLS[] == 1
            mismatched_resolution = resolve_compute_backend(:cpu)
            @test_throws ArgumentError SatelliteSimLab._run_experiment(
                backend_config,
                mismatched_resolution,
            )
            @test_throws MethodError SatelliteSimLab._run_experiment(
                backend_config,
                CPUComputeBackend(),
            )
        finally
            unregister_compute_backend!(:lab_passthrough)
        end

        register_compute_backend!(
            :stateful_probe,
            _ -> StatefulProbeComputeBackend(1),
        )
        try
            @test_throws ArgumentError SatelliteSimLab.config_hash(
                _small_config(gsl_backend=:stateful_probe),
            )
        finally
            unregister_compute_backend!(:stateful_probe)
        end

        unregister_compute_backend!(:cpu_alias)
        unregister_compute_backend!(:cpu_device)
        register_compute_backend!(:cpu_alias, _ -> CPUComputeBackend())
        register_compute_backend!(:cpu_device, _ -> LabCPUDeviceBackend())
        try
            @test_throws ArgumentError SatelliteSimLab._resolve_experiment_gsl_backend(
                _small_config(gsl_backend=:cpu_alias),
            )
            @test_throws ArgumentError SatelliteSimLab._resolve_experiment_gsl_backend(
                _small_config(gsl_backend=:cpu_device),
            )
        finally
            unregister_compute_backend!(:cpu_alias)
            unregister_compute_backend!(:cpu_device)
        end
    end

    @testset "resolved GSL cache identity excludes lifecycle ids" begin
        name = :lab_cache_identity
        unregister_compute_backend!(name)
        factory_calls = Ref(0)
        factory = _ -> begin
            factory_calls[] += 1
            LabPassthroughComputeBackend()
        end
        register_compute_backend!(name, factory)
        try
            config = _small_config(gsl_backend=name)
            first_resolution = resolve_compute_backend(config.gsl_backend)
            first_hash = SatelliteSimLab.config_hash(
                config;
                gsl_resolution=first_resolution,
            )
            first_provenance = compute_backend_provenance(first_resolution)

            register_compute_backend!(name, factory; replace=true)
            second_resolution = resolve_compute_backend(config.gsl_backend)
            second_hash = SatelliteSimLab.config_hash(
                config;
                gsl_resolution=second_resolution,
            )
            second_provenance = compute_backend_provenance(second_resolution)

            @test factory_calls[] == 2
            @test second_provenance.registration_generation >
                  first_provenance.registration_generation
            @test second_provenance.resolution_id != first_provenance.resolution_id
            @test first_hash == second_hash
        finally
            unregister_compute_backend!(name)
        end
    end

    @testset "resolved GSL metadata identity is enforced" begin
        name = :lab_mismatched_metadata
        unregister_compute_backend!(name)
        register_compute_backend!(name, _ -> LabMismatchedMetadataBackend())
        try
            @test_throws ArgumentError run_experiment(
                _small_config(gsl_backend=name),
            )
        finally
            unregister_compute_backend!(name)
        end
    end

    @testset "GSL series host-array contract" begin
        config = _small_config()
        _, positions = propagate_constellation_positions(config)
        positions_view = @view positions[:, :, :]
        result = assess_gsl_series(
            positions_view,
            Any[(0, 0, 0.0)],
            config.constraints,
        )
        @test size(result.available) == (config.constellation.T, 1, length(config.tspan))
        @test result.distance_km isa Array{Float64,3}

        empty_result = assess_gsl_series(
            positions_view,
            Any[],
            config.constraints,
        )
        @test size(empty_result.available) == (
            config.constellation.T,
            0,
            length(config.tspan),
        )
        @test_throws ArgumentError assess_gsl_series(
            positions_view,
            [(91.0, 0.0, 0.0)],
            config.constraints,
        )
        nonfinite_positions = copy(positions)
        nonfinite_positions[1, 1, 1] = NaN
        @test_throws ArgumentError assess_gsl_series(
            nonfinite_positions,
            [(0.0, 0.0, 0.0)],
            config.constraints,
        )
        @test_throws ArgumentError assess_gsl_series(
            positions_view,
            [(0.0, 0.0, 0.0)],
            PhysicalConstraints(gsl_max_range_km=0.0),
        )
    end

    @testset "config hash includes result-affecting values" begin
        baseline = ExperimentConfig(
            tspan=[0.0, 30.0, 60.0],
            users=[GroundUser("probe", 35.0, -78.0)],
        )
        changed_time = ExperimentConfig(
            tspan=[0.0, 20.0, 60.0],
            users=[GroundUser("probe", 35.0, -78.0)],
        )
        changed_user = ExperimentConfig(
            tspan=[0.0, 30.0, 60.0],
            users=[GroundUser("probe", 36.0, -78.0)],
        )
        changed_constraints = ExperimentConfig(
            tspan=[0.0, 30.0, 60.0],
            users=[GroundUser("probe", 35.0, -78.0)],
            constraints=PhysicalConstraints(gsl_min_elevation_deg=45.0),
        )
        @test SatelliteSimLab.config_hash(baseline) !=
              SatelliteSimLab.config_hash(changed_time)
        @test SatelliteSimLab.config_hash(baseline) !=
              SatelliteSimLab.config_hash(changed_user)
        @test SatelliteSimLab.config_hash(baseline) !=
              SatelliteSimLab.config_hash(changed_constraints)
        local_sources = SatelliteSimLab._local_simulation_source_files()
        @test any(path -> occursin(joinpath("src", "core", "src"), path), local_sources)
        @test any(path -> occursin(joinpath("src", "lab", "src"), path), local_sources)
        @test any(
            path -> occursin(joinpath("packages", "SatelliteSimGPU", "src"), path),
            local_sources,
        )
    end

    @testset "binary ExperimentResult cache" begin
        unregister_compute_backend!(:lab_passthrough)
        register_compute_backend!(
            :lab_passthrough,
            _ -> LabPassthroughComputeBackend(),
        )
        try
            mktempdir() do root
                cd(root) do
                    config = _small_config(
                        name="binary-cache-roundtrip",
                        gsl_backend=:lab_passthrough,
                    )
                    hash = SatelliteSimLab.config_hash(config)
                    cache_path = SatelliteSimLab._cache_path(hash)
                    legacy_path = joinpath(
                        SatelliteSimLab._cache_dir(),
                        string(hash, ".json"),
                    )
                    mkpath(dirname(legacy_path))
                    write(legacy_path, """{"legacy":"summary"}""")

                    LAB_COMPUTE_CALLS[] = 0
                    miss = cached_experiment(config)
                    miss_calls = LAB_COMPUTE_CALLS[]
                    @test miss isa ExperimentResult
                    @test miss_calls > 0
                    @test isfile(cache_path)
                    @test isfile(legacy_path)
                    @test Set(readdir(SatelliteSimLab._cache_dir())) ==
                          Set((basename(cache_path), basename(legacy_path)))

                    hit = cached_experiment(config)
                    @test hit isa ExperimentResult
                    @test typeof(hit) === typeof(miss)
                    @test all(
                        field -> repr(getfield(hit, field)) ==
                                 repr(getfield(miss, field)),
                        fieldnames(ExperimentResult),
                    )
                    @test LAB_COMPUTE_CALLS[] == miss_calls

                    envelope = open(cache_path, "r") do io
                        Serialization.deserialize(io)
                    end
                    envelope.payload[1] = envelope.payload[1] ⊻ UInt8(0x01)
                    open(cache_path, "w") do io
                        Serialization.serialize(io, envelope)
                    end
                    calls_before_corruption = LAB_COMPUTE_CALLS[]
                    repaired = cached_experiment(config)
                    @test repaired isa ExperimentResult
                    @test LAB_COMPUTE_CALLS[] > calls_before_corruption
                    @test SatelliteSimLab._read_cached_result(cache_path) isa
                          ExperimentResult

                    atomic_dir = joinpath(root, "atomic")
                    mkpath(atomic_dir)
                    atomic_path = joinpath(atomic_dir, "entry.bin")
                    write(atomic_path, "complete")
                    @test_throws ErrorException SatelliteSimLab._atomic_write(
                        atomic_path,
                    ) do io
                        write(io, "partial")
                        error("injected publication failure")
                    end
                    @test read(atomic_path, String) == "complete"
                    @test readdir(atomic_dir) == ["entry.bin"]
                end
            end
        finally
            unregister_compute_backend!(:lab_passthrough)
        end
    end

    @testset "traffic time grid alignment" begin
        grid = SatelliteSimLab._simulation_time_grid_from_tspan([0.0, 60.0, 120.0], 3)
        @test grid !== nothing
        @test timeslot_offsets(grid) == [0, 60, 120]

        @test SatelliteSimLab._simulation_time_grid_from_tspan([0.0, 60.0], 3) === nothing

        single = SatelliteSimLab._simulation_time_grid_from_tspan([0.0], 1)
        @test single !== nothing
        @test timeslot_offsets(single) == [0]
        @test SatelliteSimLab._simulation_time_grid_from_tspan([60.0], 1) === nothing

        short_final = SatelliteSimLab._simulation_time_grid_from_tspan([0.0, 3.0, 6.0, 9.0, 10.0], 5)
        @test short_final !== nothing
        @test timeslot_offsets(short_final) == [0, 3, 6, 9, 10]
        @test SatelliteSimLab._simulation_time_grid_from_tspan([0.0, 3.0, 7.0, 10.0], 4) === nothing

        fuzzy = SatelliteSimLab._simulation_time_grid_from_tspan([0.0, 60.0000000004, 120.0000000003], 3)
        @test fuzzy !== nothing
        @test timeslot_offsets(fuzzy) == [0, 60, 120]
        @test SatelliteSimLab._simulation_time_grid_from_tspan([0.0, 60.001, 120.0], 3) === nothing
        @test SatelliteSimLab._simulation_time_grid_from_tspan([0.0, NaN], 2) === nothing
        @test SatelliteSimLab._simulation_time_grid_from_tspan([0.0, Inf], 2) === nothing
    end

    @testset "run_experiment smoke" begin
        result = run_experiment(_small_config())
        @test result isa ExperimentResult
        @test result.config.name == "lab-smoke"
        @test isfinite(result.latency.avg_latency_ms)
        @test isfinite(result.network.connectivity_ratio)
        @test isfinite(result.fitness)
    end

    @testset "registered AI tools and SGP4 path" begin
        ensure_default_ai_tools!()
        @test "run_simulation" in registered_ai_tools()

        # Catalog has no starlink_tle preset in this repo; pass inline TLE text
        # (tool's documented fallback). Reuse a classic NORAD sample × 8 names.
        line1 = "1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753"
        line2 = "2 00005  34.2682 331.5174 1859667 331.7664  19.3264 10.82419157413667"
        tle_text = join(["SAT $i\n$line1\n$line2" for i in 1:8], "\n")

        result_json = execute_tool(
            "run_simulation",
            Dict(
                "constellation" => "starlink_tle",
                "topology" => "balanced",
                "propagator" => "tle_based",
                "duration_s" => 60,
                "steps" => 3,
                "max_sats" => 8,
                "tle" => tle_text,
            ),
        )
        result = JSON.parse(result_json)
        @test !haskey(result, "error")
        @test result["propagator"] == "tle_based"
        @test result["n_satellites"] == 8
        @test result["tle_source"] == 8
        @test isfinite(result["avg_latency_ms"])

        varied_tle = _varied_tle_text()
        tle_elements = SatelliteSimLab._load_tle_lines(split(varied_tle, '\n'))
        time_grid = SimulationTimeGrid(
            default_starlink_simulation_epoch(),
            600,
            300,
        )
        positions = propagate_to_ecef(tle_elements, time_grid)
        strategy = parse_ai_topology("minimal", 8)
        candidates = SatelliteSimLab._topology_isl_candidates(strategy, 8, 2)
        _, last_frame_available, _ = assess_routing(
            positions,
            8,
            2,
            strategy,
            LEO_DEFAULTS,
        )
        @test !isempty(candidates)
        @test isempty(last_frame_available)

        traffic_args = Dict{String,Any}(
            "constellation" => "sgp4_traffic_probe",
            "topology" => "minimal",
            "propagator" => "tle_based",
            "duration_s" => 600,
            "steps" => 3,
            "max_sats" => 8,
            "tle" => varied_tle,
            "traffic" => "uniform",
            "ground_stations" => [
                Dict{String,Any}(
                    "id" => 1,
                    "name" => "source",
                    "lat" => 0.0,
                    "lon" => 0.0,
                ),
                Dict{String,Any}(
                    "id" => 2,
                    "name" => "destination",
                    "lat" => 10.0,
                    "lon" => 10.0,
                ),
            ],
            "ground_pairs" => [[1, 2]],
        )
        traffic_result = JSON.parse(
            execute_tool("run_simulation", traffic_args);
            allownan=true,
        )
        @test !haskey(traffic_result, "error")
        @test traffic_result["traffic_evaluation_ran"] == true
        @test traffic_result["traffic_fallback"] == false
        @test traffic_result["traffic_time_steps"] == 3
        @test traffic_result["traffic_assignments"] == 2

        invalid_traffic_args = deepcopy(traffic_args)
        invalid_traffic_args["ground_stations"][1]["alt_km"] = NaN
        invalid_result = JSON.parse(
            execute_tool("run_simulation", invalid_traffic_args);
            allownan=true,
        )
        @test haskey(invalid_result, "error")
        @test !haskey(invalid_result, "traffic_fallback")
    end

    @testset "AI run_simulation traffic AON bridge" begin
        ensure_default_ai_tools!()
        schema = SatelliteSimLab.get_ai_tool("run_simulation").input_schema
        properties = schema["properties"]
        @test haskey(properties, "traffic")
        @test haskey(properties, "ground_stations")
        @test haskey(properties, "ground_pairs")

        # Build stable ground points from the same Walker geometry used by the tool.
        seed = ExperimentConfig(
            constellation_params = Dict(:T => 48.0, :P => 8.0, :F => 1.0, :alt_km => 550.0, :inc_deg => 53.0),
            tspan = collect(range(0.0, 120.0; length = 3)),
            topology_strategy = GridPlusStrategy(),
        )
        _, positions = propagate_constellation_positions(seed)
        src_lat, src_lon = _subpoint_deg(positions, 1)
        dst_lat, dst_lon = _subpoint_deg(positions, 2)

        raw = SatelliteSimLab.execute_tool(
            "run_simulation",
            Dict{String,Any}(
                "constellation" => "walker 48/8/1",
                "duration_s" => 120,
                "steps" => 3,
                "topology" => "balanced",
                "propagator" => "fast",
                "traffic" => "uniform",
                "ground_stations" => [
                    Dict{String,Any}("id" => 1, "name" => "source", "lat" => src_lat, "lon" => src_lon, "alt_km" => 0.0),
                    Dict{String,Any}("id" => 2, "name" => "destination", "lat" => dst_lat, "lon" => dst_lon, "alt_km" => 0.0),
                ],
                "ground_pairs" => [[1, 2]],
            ),
        )
        data = JSON.parse(raw; allownan = true)

        @test data["traffic_enabled"] == true
        @test data["traffic_demands"] == 1
        @test data["ground_stations"] == 2
        @test data["ground_pairs"] == 1
        @test data["traffic_evaluation_ran"] == true
        @test data["traffic_fallback"] == false
        @test data["traffic_time_steps"] == 3
        @test data["traffic_assignments"] == 2
        @test data["offered_mbps"] == 100.0
        @test data["carried_mbps"] + data["dropped_mbps"] == data["offered_mbps"]

        default_raw = SatelliteSimLab.execute_tool(
            "run_simulation",
            Dict{String,Any}(
                "constellation" => "walker 6/3/1",
                "duration_s" => 60,
                "steps" => 2,
                "topology" => "minimal",
                "propagator" => "fast",
            ),
        )
        default_data = JSON.parse(default_raw; allownan = true)
        @test default_data["traffic_enabled"] == false
        @test default_data["traffic_demands"] == 0
        @test default_data["traffic_evaluation_ran"] == false
    end

    @testset "AI LLMProvider fake HTTP bridge" begin
        # 起本地 fake server，拦截 OpenAI 兼容 /chat/completions 请求。
        # handler 里不写 @test（它跑在 server 的 task 上，@testset 无法收集断言），
        # 改为把请求四要素捕获到共享容器，chat() 返回后在主 task 里统一断言。
        captured = Dict{String,Any}()

        server = HTTP.serve!("127.0.0.1", 0; listenany = true) do request::HTTP.Request
            captured["method"] = request.method
            captured["target"] = String(request.target)
            captured["authorization"] = HTTP.header(request, "Authorization")
            captured["body"] = JSON.parse(String(request.body))

            response = Dict(
                "choices" => [
                    Dict(
                        "message" => Dict(
                            "content" => "fake-ok",
                            "tool_calls" => [
                                Dict(
                                    "id" => "call_1",
                                    "type" => "function",
                                    "function" => Dict(
                                        "name" => "run_simulation",
                                        "arguments" => JSON.json(Dict("duration_s" => 60)),
                                    ),
                                ),
                            ],
                        ),
                    ),
                ],
            )
            return HTTP.Response(200, ["Content-Type" => "application/json"], JSON.json(response))
        end

        try
            port = HTTP.port(server)
            provider = LLMProvider(
                key = "fake-key",
                model = "fake-model",
                url = "http://127.0.0.1:$port/v1",
                readtimeout_s = 5,
            )

            messages = [Dict("role" => "user", "content" => "hello fake")]
            tools = [
                Dict(
                    "name" => "run_simulation",
                    "description" => "fake tool",
                    "input_schema" => Dict(
                        "type" => "object",
                        "properties" => Dict("duration_s" => Dict("type" => "integer")),
                        "required" => ["duration_s"],
                    ),
                ),
            ]

            message = chat(provider, messages, tools)

            # 响应解析
            @test message.content == "fake-ok"
            @test length(message.tool_calls) == 1
            @test message.tool_calls[1].id == "call_1"
            @test message.tool_calls[1].name == "run_simulation"
            @test message.tool_calls[1].args["duration_s"] == 60

            # 请求格式 + Authorization header（主 task 断言，可靠计入 testset）
            @test captured["method"] == "POST"
            @test captured["target"] == "/v1/chat/completions"
            @test captured["authorization"] == "Bearer fake-key"

            body = captured["body"]
            @test body["model"] == "fake-model"
            @test body["messages"][1]["role"] == "user"
            @test body["messages"][1]["content"] == "hello fake"

            # tools 字段（OpenAI function 格式）
            @test body["tools"][1]["type"] == "function"
            @test body["tools"][1]["function"]["name"] == "run_simulation"
            @test body["tool_choice"] == "auto"
        finally
            close(server)
        end
    end

    @testset "AI SimAgent tool loop fake HTTP bridge" begin
        # 复现 probe 的两轮工具循环：第 1 轮 fake server 返回 tool_call(list_available)，
        # SimAgent 真实执行该工具，把结果作为 tool 消息回传；第 2 轮返回最终文本答案。
        # handler 只按请求序号返回对应响应并捕获 body，全部断言放在主 task。
        received = Vector{Dict{String,Any}}()
        headers = Vector{Union{Nothing,String}}()
        methods = String[]
        targets = String[]

        server = HTTP.serve!("127.0.0.1", 0; listenany = true) do request::HTTP.Request
            push!(methods, request.method)
            push!(targets, String(request.target))
            push!(headers, HTTP.header(request, "Authorization"))
            body = JSON.parse(String(request.body))
            push!(received, body)

            if length(received) == 1
                # 第 1 轮：要求调用 list_available(propagators)
                response = Dict(
                    "choices" => [
                        Dict(
                            "message" => Dict(
                                "content" => nothing,
                                "tool_calls" => [
                                    Dict(
                                        "id" => "call_list_available_1",
                                        "type" => "function",
                                        "function" => Dict(
                                            "name" => "list_available",
                                            "arguments" => JSON.json(Dict("what" => "propagators")),
                                        ),
                                    ),
                                ],
                            ),
                        ),
                    ],
                )
                return HTTP.Response(200, ["Content-Type" => "application/json"], JSON.json(response))
            elseif length(received) == 2
                # 第 2 轮：工具结果已回传，返回最终答案
                response = Dict(
                    "choices" => [
                        Dict("message" => Dict("content" => "传播器包括 fast/balanced/precise/tle_based。")),
                    ],
                )
                return HTTP.Response(200, ["Content-Type" => "application/json"], JSON.json(response))
            end
            return HTTP.Response(500, JSON.json(Dict("error" => "unexpected request")))
        end

        session_id = "test_fake_openai_tool_loop_$(rand(UInt))"
        try
            port = HTTP.port(server)
            provider = LLMProvider(
                key = "fake-key",
                model = "fake-model",
                url = "http://127.0.0.1:$port/v1",
                readtimeout_s = 5,
            )
            agent = SimAgent(provider; session_id = session_id)
            reply = run_agent(agent, "列出可用传播器")

            # 最终答案 + 工具循环发生
            @test reply == "传播器包括 fast/balanced/precise/tle_based。"
            @test length(received) == 2
            @test count(m -> get(m, "role", "") == "tool", agent.messages) == 1

            # 两轮请求都命中 OpenAI 兼容端点 + Authorization
            @test methods == ["POST", "POST"]
            @test targets == ["/v1/chat/completions", "/v1/chat/completions"]
            @test headers == ["Bearer fake-key", "Bearer fake-key"]

            # 第 1 轮请求格式：system + user 消息、tools 字段、tool_choice
            first_body = received[1]
            @test first_body["messages"][1]["role"] == "system"
            @test first_body["messages"][2]["role"] == "user"
            @test first_body["messages"][2]["content"] == "列出可用传播器"
            @test first_body["tools"][1]["type"] == "function"
            @test first_body["tool_choice"] == "auto"

            # 第 2 轮请求：assistant tool_call + tool 结果消息（含真实工具输出 tle_based）
            second_msgs = received[2]["messages"]
            assistant_msg = second_msgs[end - 1]
            tool_msg = second_msgs[end]
            @test assistant_msg["role"] == "assistant"
            @test assistant_msg["tool_calls"][1]["id"] == "call_list_available_1"
            @test tool_msg["role"] == "tool"
            @test tool_msg["tool_call_id"] == "call_list_available_1"
            @test occursin("tle_based", tool_msg["content"])
        finally
            close(server)
            session_dir = dirname(SessionMemory(session_id = session_id).transcript_path)
            isdir(session_dir) && rm(session_dir; recursive = true, force = true)
            clear_hooks!()
        end
    end

    @testset "AI team graph run_simulation (mock provider)" begin
        # 镜像自 scripts/probe_ai_team_graph_run_simulation.jl：
        # 用 MockProvider 脚本化 planner -> runner -> reviewer，确认 runner 真实执行 run_simulation。
        # 确定性、无真实 LLM / API key / 网络。
        cleanup_team_sessions = function (sid::String)
            for suffix in ("", "_planner", "_runner", "_reviewer")
                path = joinpath("data", "sessions", sid * suffix)
                isdir(path) && rm(path; recursive = true, force = true)
            end
        end

        session_id = "lab_ai_team_graph_run_simulation_$(rand(UInt))"

        try
            provider = MockProvider([
                AssistantMessage("计划：运行一个 6 颗星的小规模仿真，然后审查指标。", ToolCall[]),
                AssistantMessage("", [
                    ToolCall(
                        "call_runner_sim",
                        "run_simulation",
                        Dict{String,Any}(
                            "constellation" => "walker 6/3/1",
                            "duration_s" => 60,
                            "steps" => 2,
                            "topology" => "minimal",
                            "propagator" => "fast",
                        ),
                    ),
                ]),
                AssistantMessage(
                    "执行完成：仿真工具返回 coverage_ratio、avg_latency_ms、connectivity_ratio。",
                    ToolCall[],
                ),
                AssistantMessage("最终结论：通过。结果可信，但规模很小，只能作为 smoke。", ToolCall[]),
            ])

            team = AgentTeam(provider; session_id = session_id)
            result = run_team_graph(team, default_team_graph(), "用多智能体跑一个最小仿真实验")

            @test result.state.status == :completed
            @test [msg.from for msg in result.transcript] == ["planner", "runner", "reviewer"]
            @test occursin("最终结论", result.final_answer)

            runner_messages = team.agents["runner"].messages
            tool_messages = [msg for msg in runner_messages if get(msg, "role", "") == "tool"]
            @test length(tool_messages) == 1

            payload = JSON.parse(tool_messages[1]["content"]; allownan = true)
            @test haskey(payload, "coverage_ratio")
            @test haskey(payload, "avg_latency_ms")
            @test haskey(payload, "connectivity_ratio")
            @test payload["n_satellites"] == 6

            runner_ledger = ledger_path(team.agents["runner"].memory)
            @test isfile(runner_ledger)
            @test any(
                line -> occursin("\"event_type\":\"tool_call\"", line) &&
                        occursin("\"tool\":\"run_simulation\"", line) &&
                        occursin("\"status\":\"succeeded\"", line),
                readlines(runner_ledger),
            )
        finally
            cleanup_team_sessions(session_id)
            clear_hooks!()
        end
    end

    @testset "Traffic bridge uses GroundStation positions" begin
        ground_stations = [
            GroundStation(
                id = 1,
                name = "beijing",
                position = GeodeticPosition(39.9042, 116.4074, 0.0),
            ),
            GroundStation(
                id = 2,
                name = "singapore",
                position = GeodeticPosition(1.3521, 103.8198, 0.0),
            ),
        ]
        config = ExperimentConfig(
            name = "traffic-bridge-test",
            constellation_params = Dict(
                :T => 24.0,
                :P => 6.0,
                :F => 1.0,
                :alt_km => 550.0,
                :inc_deg => 53.0,
            ),
            tspan = collect(0.0:60.0:120.0),
            topology_strategy = GridPlusStrategy(),
            routing_algorithm = DijkstraRouting(),
            constraints = PhysicalConstraints(
                isl_max_range_km = 12000.0,
                isl_require_los = false,
                gsl_min_elevation_deg = 5.0,
                gsl_max_range_km = 20000.0,
            ),
            ground_stations = ground_stations,
            users = [
                GroundUser("beijing", 39.9042, 116.4074, 20.0, 100.0, "smoke"),
                GroundUser("singapore", 1.3521, 103.8198, 20.0, 100.0, "smoke"),
            ],
            ground_pairs = [(1, 2)],
        )
        result = run_experiment(config)
        @test length(result.config.traffic_demands) == 1
        @test result.traffic_evaluation !== nothing
        @test length(result.traffic_evaluation.assignments_by_time) == length(config.tspan)
        @test length(result.traffic_evaluation.link_loads_by_time) == length(config.tspan)
    end

    @testset "export and persistence tolerate NaN coverage" begin
        result = run_experiment(_small_config(; name="persist-smoke"))
        as_dict = to_dict(result)
        @test haskey(as_dict, :avg_lat_ms)
        @test to_csv(["persist" => result]) isa String
        @test to_markdown(["persist" => result]) isa String

        record = ExperimentRecord(result.config, result; notes="test")
        path = save_experiment(record)
        loaded = load_experiment(record.id)
        @test isfile(path)
        @test loaded.id == record.id
        @test haskey(loaded.result, "coverage")
    end
end

# --- from main: topology candidate / traffic reachability regression ---
struct SingleCandidateStrategy <: AbstractTopologyStrategy
    edge::Tuple{Int,Int}
end

function SatelliteSimNet.generate_topology(
    strategy::SingleCandidateStrategy,
    ::Int,
    ::Int,
)::TopologyOutput
    return TopologyOutput(Tuple{Int,Int}[strategy.edge], Tuple{Int,Int}[], "SingleCandidate")
end

function _distance_km(positions::Array{Float64,3}, a::Int, b::Int, time_index::Int)::Float64
    return sqrt(sum((positions[a, time_index, k] - positions[b, time_index, k])^2 for k in 1:3))
end

function _subpoint_ground_station(
    id::Int,
    name::String,
    positions::Array{Float64,3},
    satellite_id::Int,
    time_index::Int,
)::GroundStation
    x = positions[satellite_id, time_index, 1]
    y = positions[satellite_id, time_index, 2]
    z = positions[satellite_id, time_index, 3]
    latitude_deg = atan(z, hypot(x, y)) * 180 / pi
    longitude_deg = atan(y, x) * 180 / pi
    return GroundStation(id, name, GeodeticPosition(latitude_deg, longitude_deg, 0.0))
end

@testset "SatelliteSimLab network traffic candidates" begin
    base_config = ExperimentConfig(
        name = "candidate-probe",
        constellation_params = Dict(
            :T => 6.0,
            :P => 3.0,
            :F => 1.0,
            :alt_km => 550.0,
            :inc_deg => 53.0,
        ),
        tspan = [0.0, 3000.0],
        topology_strategy = SingleCandidateStrategy((1, 4)),
        constraints = PhysicalConstraints(
            isl_max_range_km = 5000.0,
            isl_require_los = false,
            isl_max_capacity_mbps = 1000.0,
            gsl_min_elevation_deg = -90.0,
            gsl_max_range_km = 1.0e9,
            gsl_base_capacity_mbps = 1000.0,
        ),
        traffic = TrafficDemand[],
    )
    _, positions = propagate_constellation_positions(base_config)

    first_distance = _distance_km(positions, 1, 4, 1)
    last_distance = _distance_km(positions, 1, 4, 2)
    @test first_distance < last_distance

    constraints = PhysicalConstraints(
        isl_max_range_km = (first_distance + last_distance) / 2,
        isl_require_los = false,
        isl_max_capacity_mbps = 1000.0,
        gsl_min_elevation_deg = -90.0,
        gsl_max_range_km = 1.0e9,
        gsl_base_capacity_mbps = 1000.0,
    )
    demand = TrafficDemand(
        id = 1,
        source_ground_id = 1,
        destination_ground_id = 2,
        start_elapsed_s = 0,
        end_elapsed_s = 3001,
        rate_mbps = 100.0,
    )
    config = ExperimentConfig(
        name = "traffic-candidates-use-full-topology",
        constellation_params = Dict(
            :T => 6.0,
            :P => 3.0,
            :F => 1.0,
            :alt_km => 550.0,
            :inc_deg => 53.0,
        ),
        tspan = [0.0, 3000.0],
        topology_strategy = SingleCandidateStrategy((1, 4)),
        routing_algorithm = DijkstraRouting(),
        constraints = constraints,
        traffic = TrafficDemand[demand],
        ground_stations = GroundStation[
            _subpoint_ground_station(1, "source", positions, 1, 1),
            _subpoint_ground_station(2, "destination", positions, 4, 1),
        ],
    )

    result = full_constellation_assessment(config)
    @test result.traffic_evaluation !== nothing

    assignments_t1 = SatelliteSimTraffic.traffic_assignments_at(result.traffic_evaluation, 1)
    @test length(assignments_t1) == 1
    @test assignments_t1[1].route.reachable
    @test assignments_t1[1].route.satellite_path == [1, 4]
    @test assignments_t1[1].carried_mbps == 100.0

    assignments_t2 = SatelliteSimTraffic.traffic_assignments_at(result.traffic_evaluation, 2)
    @test length(assignments_t2) == 1
    @test !assignments_t2[1].route.reachable
    @test assignments_t2[1].route.reason == :isl_unreachable
    @test assignments_t2[1].dropped_mbps == 100.0
end

@testset "Lab state and checkpoint accept position views" begin
    parent_positions = zeros(Float32, 2, 2, 3)
    positions = @view parent_positions[:, :, :]

    state = ExperimentState()
    state.positions = positions
    @test state.positions === positions

    mktempdir() do directory
        cd(directory) do
            path = save_checkpoint(
                1,
                "view-contract",
                positions,
                Dict{String,Any}("ok" => true),
                0.1,
            )
            @test isfile(path)
            @test load_checkpoint(path).step == 1
        end
    end
end

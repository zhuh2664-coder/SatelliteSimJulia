using Test
using SatelliteSimBackends

struct MissingBackend <: AbstractOrbitBackend end
struct ConfiguredBackend <: AbstractOrbitBackend
    scale::Float64
end
struct ConfiguredComputeBackend <: AbstractComputeBackend
    precision::Symbol
end

@testset "SatelliteSimBackends contract" begin
    @test backend_name(MissingBackend()) == "MissingBackend"
    @test backend_capabilities(MissingBackend()).frames == (:ecef,)
    @test_throws MethodError propagate_orbit(MissingBackend(), [1], [0.0])

    valid = OrbitResult(zeros(2, 3, 3), Dict{String,Any}())
    @test validate_orbit_result(valid; expected_satellites=2, expected_times=3) === valid
    @test_throws ArgumentError validate_orbit_result(OrbitResult(zeros(2, 3, 2), Dict{String,Any}()))
end

@testset "Compute backend contract" begin
    cpu = create_compute_backend(:cpu)
    @test cpu isa CPUComputeBackend
    @test compute_backend_name(cpu) == "cpu"
    @test :gsl_series in compute_backend_capabilities(cpu).operations
    @test compute_backend_fingerprint(cpu).name == "cpu"
    @test compute_backend_cache_token(cpu) === nothing
    @test isempty(compute_backend_source_files(cpu))
    @test compute_backend_registered(:cpu)
    @test :cpu in available_compute_backends()
    @test !unregister_compute_backend!(:cpu)
    @test_throws ArgumentError create_compute_backend(:cpu; precision=:float32)
    @test_throws ArgumentError register_compute_backend!(:cpu, _ -> cpu)

    valid = GSLSeriesResult(
        falses(2, 3, 4),
        zeros(2, 3, 4),
        zeros(2, 3, 4),
        zeros(2, 3, 4),
        Dict{String,Any}("backend" => "cpu"),
    )
    @test validate_gsl_series_result(
        valid;
        expected_satellites=2,
        expected_stations=3,
        expected_times=4,
    ) === valid
    @test_throws ArgumentError validate_gsl_series_result(
        GSLSeriesResult(
            falses(2, 3, 4),
            zeros(2, 3, 3),
            zeros(2, 3, 4),
            zeros(2, 3, 4),
            Dict{String,Any}(),
        ),
    )
end

@testset "Orbit backend discovery and configuration" begin
    spec = OrbitBackendSpec("contract_test"; scale=2)
    @test spec.name == :contract_test
    @test spec.options == (scale=2,)
    @test OrbitBackendSpec("contract_test", (scale=2,)) == spec
    @test_throws ArgumentError OrbitBackendSpec(Symbol(""))

    unregister_orbit_backend!(:contract_test)
    register_orbit_backend!(
        :contract_test,
        options -> ConfiguredBackend(Float64(get(options, :scale, 1.0))),
    )
    try
        @test orbit_backend_registered("contract_test")
        @test :contract_test in available_orbit_backends()
        backend = create_orbit_backend(spec)
        @test backend isa ConfiguredBackend
        @test backend.scale == 2.0
        @test_throws ArgumentError register_orbit_backend!(:contract_test, _ -> MissingBackend())
    finally
        @test unregister_orbit_backend!(:contract_test)
    end
    @test !orbit_backend_registered(:contract_test)

    error = try
        create_orbit_backend(:not_loaded)
        nothing
    catch caught
        caught
    end
    @test error isa ArgumentError
    @test occursin("load the optional backend package", sprint(showerror, error))

    register_orbit_backend!(:invalid_factory, _ -> :not_a_backend; replace=true)
    try
        @test_throws ArgumentError create_orbit_backend(:invalid_factory)
    finally
        unregister_orbit_backend!(:invalid_factory)
    end
end

@testset "Compute backend discovery and configuration" begin
    spec = ComputeBackendSpec("contract_compute"; precision="float32")
    @test spec.name == :contract_compute
    @test spec.options == (precision="float32",)
    @test ComputeBackendSpec("contract_compute", (precision="float32",)) == spec
    @test_throws ArgumentError ComputeBackendSpec(Symbol(""))

    unregister_compute_backend!(:contract_compute)
    register_compute_backend!(
        :contract_compute,
        options -> ConfiguredComputeBackend(Symbol(get(options, :precision, "float64"))),
    )
    try
        @test compute_backend_registered("contract_compute")
        @test :contract_compute in available_compute_backends()
        backend = create_compute_backend(spec)
        @test backend isa ConfiguredComputeBackend
        @test backend.precision == :float32
        @test_throws ArgumentError register_compute_backend!(
            :contract_compute,
            _ -> ConfiguredComputeBackend(:float64),
        )
    finally
        @test unregister_compute_backend!(:contract_compute)
    end
    @test !compute_backend_registered(:contract_compute)

    error = try
        create_compute_backend(:not_loaded)
        nothing
    catch caught
        caught
    end
    @test error isa ArgumentError
    @test occursin("register the device backend", sprint(showerror, error))

    register_compute_backend!(:invalid_compute_factory, _ -> :not_a_backend; replace=true)
    try
        @test_throws ArgumentError create_compute_backend(:invalid_compute_factory)
    finally
        unregister_compute_backend!(:invalid_compute_factory)
    end
end

using Test
using SatelliteSimBackends

struct MissingBackend <: AbstractOrbitBackend end
struct ConfiguredBackend <: AbstractOrbitBackend
    scale::Float64
end

@testset "SatelliteSimBackends contract" begin
    @test backend_name(MissingBackend()) == "MissingBackend"
    @test backend_capabilities(MissingBackend()).frames == (:ecef,)
    @test_throws MethodError propagate_orbit(MissingBackend(), [1], [0.0])

    valid = OrbitResult(zeros(2, 3, 3), Dict{String,Any}())
    @test validate_orbit_result(valid; expected_satellites=2, expected_times=3) === valid
    @test_throws ArgumentError validate_orbit_result(OrbitResult(zeros(2, 3, 2), Dict{String,Any}()))
end

@testset "Orbit backend discovery and configuration" begin
    spec = OrbitBackendSpec("contract_test"; scale=2)
    @test spec.name == :contract_test
    @test spec.options == (scale=2,)
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

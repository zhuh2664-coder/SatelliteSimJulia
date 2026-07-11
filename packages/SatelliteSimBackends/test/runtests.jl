using Test
using SatelliteSimBackends

struct MissingBackend <: AbstractOrbitBackend end

@testset "SatelliteSimBackends contract" begin
    @test backend_name(MissingBackend()) == "MissingBackend"
    @test backend_capabilities(MissingBackend()).frames == (:ecef,)
    @test_throws MethodError propagate_orbit(MissingBackend(), [1], [0.0])

    valid = OrbitResult(zeros(2, 3, 3), Dict{String,Any}())
    @test validate_orbit_result(valid; expected_satellites=2, expected_times=3) === valid
    @test_throws ArgumentError validate_orbit_result(OrbitResult(zeros(2, 3, 2), Dict{String,Any}()))
end

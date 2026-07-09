using Test
using SatelliteSimBackends
using SatelliteSimStubBackend

@testset "stub backend package contract" begin
    backend = StubOrbitBackend()
    result = propagate_orbit(backend, 1:3, 0.0:5.0:10.0)
    @test backend_capabilities(backend).deterministic
    @test size(result.positions_ecef_km) == (3, 3, 3)
    @test result.metadata["backend"] == "StubOrbitBackend"
end

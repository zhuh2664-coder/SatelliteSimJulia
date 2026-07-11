using Test
using SatelliteSimBackends
using SatelliteSimStubBackend

@testset "SatelliteSimStubBackend" begin
    backend = StubOrbitBackend()
    result = propagate_orbit(backend, [:sat1, :sat2], [0.0, 10.0])
    @test size(result.positions_ecef_km) == (2, 2, 3)
    @test result.positions_ecef_km[1, 2, 2] == 75.0
    @test result.positions_ecef_km[2, 1, 3] == 10.0
    @test result.metadata["deterministic"] == true
end

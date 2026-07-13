using Test
using SatelliteSimBackends
using SatelliteSimStubBackend

@testset "SatelliteSimStubBackend" begin
    @test orbit_backend_registered(:stub)
    configured = create_orbit_backend(:stub; satellite_spacing_km=25.0)
    @test configured isa StubOrbitBackend
    @test configured.satellite_spacing_km == 25.0
    @test orbit_backend_cache_token(configured).satellite_spacing_km == 25.0
    @test endswith(
        only(orbit_backend_source_files(configured)),
        "SatelliteSimStubBackend.jl",
    )

    backend = StubOrbitBackend()
    result = propagate_orbit(backend, [:sat1, :sat2], [0.0, 10.0])
    @test size(result.positions_ecef_km) == (2, 2, 3)
    @test result.positions_ecef_km[1, 2, 2] == 75.0
    @test result.positions_ecef_km[2, 1, 3] == 10.0
    @test result.metadata["deterministic"] == true
end

using Test
using SatelliteSimBackends
using SatelliteSimJuliaSpaceBackend
using SatelliteSimOrbit

@testset "SatelliteSimJuliaSpaceBackend" begin
    elements = generate_walker_delta(T=4, P=2, F=1, alt_km=550.0, inc_deg=53.0)
    result = propagate_orbit(JuliaSpaceOrbitBackend(), elements, [0.0, 10.0])
    @test size(result.positions_ecef_km) == (4, 2, 3)
    @test result.metadata["propagator"] == "two_body"
end

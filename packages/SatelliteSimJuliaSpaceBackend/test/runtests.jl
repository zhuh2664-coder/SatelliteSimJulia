using Test
using SatelliteSimBackends
using SatelliteSimJuliaSpaceBackend
using SatelliteSimOrbit

# Reference vector for the version-locked native two-body path.  Units are km,
# frame is ECEF, and the tolerance is 1 m so backend numerical drift is visible.
const TWO_BODY_ECEF_GOLDEN_KM = [
    -3105.134797541  6185.569497983    0.0;
    -3316.764813342  6063.846253906  363.564520598;
    -3515.279883685  5917.798234203  725.556090761;
]
const TWO_BODY_ECEF_ATOL_KM = 1e-3

@testset "SatelliteSimJuliaSpaceBackend" begin
    @test orbit_backend_registered(:julia_space)
    configured = create_orbit_backend(:julia_space; propagator=:j2)
    @test configured isa JuliaSpaceOrbitBackend
    @test configured.propagator == :j2

    elements = generate_walker_delta(T=4, P=2, F=1, alt_km=550.0, inc_deg=53.0)
    result = propagate_orbit(JuliaSpaceOrbitBackend(), elements, [0.0, 10.0])
    @test size(result.positions_ecef_km) == (4, 2, 3)
    @test result.metadata["propagator"] == "two_body"

    golden_elements = generate_walker_delta(T=1, P=1, F=0, alt_km=550.0, inc_deg=53.0)
    golden_result = propagate_orbit(
        JuliaSpaceOrbitBackend(), golden_elements, [0.0, 60.0, 120.0],
    )
    @test golden_result.metadata["frame"] == "ecef"
    @test golden_result.positions_ecef_km[1, :, :] ≈ TWO_BODY_ECEF_GOLDEN_KM atol=TWO_BODY_ECEF_ATOL_KM rtol=0

    # The Orbit facade must return exactly the bare array contract used downstream.
    facade_positions = propagate_to_ecef(
        JuliaSpaceOrbitBackend(), golden_elements, [0.0, 60.0, 120.0],
    )
    @test facade_positions == golden_result.positions_ecef_km
end

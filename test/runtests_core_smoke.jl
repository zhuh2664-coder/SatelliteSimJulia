using Test
using SatelliteSimFoundation
using SatelliteSimOrbit
using SatelliteSimLink
using SatelliteSimNet
using SatelliteSimMetrics
using SatelliteSimTraffic

@testset "core/sim package smoke" begin
    elements = generate_walker_delta(T=8, P=4, F=1, alt_km=550.0, inc_deg=53.0)
    positions = propagate_to_ecef(elements, [0.0, 30.0])
    @test size(positions) == (8, 2, 3)

    links = generate_topology(GridPlusStrategy(), 8, 4).static_links
    samples = evaluate_isl_batch(position_at_instant(positions, 1), links; constraints=LEO_DEFAULTS)
    @test length(samples) == length(links)
    @test all(sample -> hasproperty(sample, :latency_ms), samples)
end

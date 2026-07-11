using Test
using SatelliteSimFoundation
using SatelliteSimOrbit
using SatelliteSimLink
using SatelliteSimNet

@testset "bare-array orchestration contract" begin
    elements = generate_walker_delta(T=8, P=4, F=1, alt_km=550.0, inc_deg=53.0)
    positions = propagate_to_ecef(elements, [0.0, 30.0, 60.0])

    @test positions isa Array{Float64,3}
    @test n_satellites(positions) == 8
    @test n_timesteps(positions) == 3

    instant = position_at_instant(positions, 2)
    @test instant isa SubArray
    @test size(instant) == (8, 3)
    @test parent(instant) === positions

    links = generate_topology(GridPlusStrategy(), 8, 4).static_links
    evaluations = evaluate_isl_batch(instant, links; constraints=LEO_DEFAULTS)
    @test length(evaluations) == length(links)
end

using Test
using SatelliteSimCore

@testset "bare-array CI contract" begin
    elems = generate_walker_delta(; T = 6, P = 2, F = 1)
    tspan = collect(range(0.0, 600.0; length = 5))
    pos = propagate_to_ecef(elems, tspan)
    @test pos isa Array{Float64,3}
    @test ndims(pos) == 3
    @test all(isfinite, pos)
    @test propagate_to_ecef === SatelliteSimCore.propagate_to_ecef
end

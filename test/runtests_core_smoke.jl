#!/usr/bin/env julia
# envs/core 轻量冒烟：不加载伞包 SatelliteSimJulia，验证主链可实例化。

using Test
using SatelliteSimCore

@testset "core smoke" begin
    elems = generate_walker_delta(; T = 6, P = 2, F = 1)
    @test length(elems) == 6
    tspan = [0.0, 60.0, 120.0]
    pos = propagate_to_ecef(elems, tspan)
    @test size(pos) == (6, 3, 3)
    @test all(isfinite, pos)
end

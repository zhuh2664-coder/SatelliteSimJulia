#!/usr/bin/env julia
# envs/gmat GMAT+ODE 隔离冒烟

using Test
using GMAT

@testset "gmat env smoke" begin
    @test isdefined(Main, :GMAT)
end

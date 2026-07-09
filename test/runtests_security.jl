#!/usr/bin/env julia
# envs/security 回归：攻防层独立于伞包运行。

push!(LOAD_PATH, "@stdlib")

using Test
using SatelliteSimSecurity

include(joinpath(@__DIR__, "test_security.jl"))

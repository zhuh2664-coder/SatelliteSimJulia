using Test
using SatelliteSimOpt

include(joinpath(@__DIR__, "..", "..", "..", "test", "test_opt_routing.jl"))
include("test_sgp4_e2e.jl")

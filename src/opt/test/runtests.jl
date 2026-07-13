using Test
using SatelliteSimOpt

include(joinpath(@__DIR__, "..", "..", "..", "test", "test_opt_routing.jl"))
include("test_sgp4_e2e.jl")
include("test_sgp4_network_kpi.jl")

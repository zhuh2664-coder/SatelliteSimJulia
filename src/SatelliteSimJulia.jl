module SatelliteSimJulia

using Reexport

# Phase 0': 日常仿真伞包 — 主链 + Lab。Opt/Viz/Security/Distributed 见 envs/* 或 [extras]。
@reexport using SatelliteSimCore
@reexport using SatelliteSimNet
@reexport using SatelliteSimNetSim
@reexport using SatelliteSimLab
@reexport using SatelliteSimTraffic

include("cli/SimCLI.jl")
using .SimCLI

"""
    satnet(args::Vector{String})

SimCLI 入口。`bin/satnet.jl` 调用此函数。
"""
satnet(args::Vector{String}) = SimCLI.command_main(args)

include("cli/SimCLI.jl")
using .SimCLI

"""
    satnet(args::Vector{String})

SimCLI 入口。`bin/satnet.jl` 调用此函数。
"""
satnet(args::Vector{String}) = SimCLI.command_main(args)

end # module

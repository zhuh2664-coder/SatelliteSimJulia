module SatelliteSimJulia

using Reexport

@reexport using SatelliteSimCore
@reexport using SatelliteSimNet
@reexport using SatelliteSimOpt
@reexport using SatelliteSimSecurity
@reexport using SatelliteSimLab
@reexport using SatelliteSimTraffic
@reexport using SatelliteSimDistributed
@reexport using SatelliteSimViz

include("cli/SimCLI.jl")
using .SimCLI

"""
    satnet(args::Vector{String})

SimCLI 入口。`bin/satnet.jl` 调用此函数。
"""
satnet(args::Vector{String}) = SimCLI.command_main(args)

end # module

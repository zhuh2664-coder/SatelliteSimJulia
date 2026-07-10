module SatelliteSimJulia

using Reexport

# 日常仿真伞包：主链 + Lab，并保留 Opt/Security 的兼容入口。
@reexport using SatelliteSimCore
@reexport using SatelliteSimNet
@reexport using SatelliteSimLab
@reexport using SatelliteSimTraffic
@reexport using SatelliteSimSecurity
using SatelliteSimOpt: aon_throughput

export aon_throughput

include("cli/SimCLI.jl")
using .SimCLI

"""
    satnet(args::Vector{String})

SimCLI 入口。`bin/satnet.jl` 调用此函数。
"""
satnet(args::Vector{String}) = SimCLI.command_main(args)

end # module

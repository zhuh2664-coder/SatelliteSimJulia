module SatelliteSimJulia

using Reexport

@reexport using SatelliteSimCore
@reexport using SatelliteSimNet
@reexport using SatelliteSimLab
@reexport using SatelliteSimTraffic

include("cli/SimCLI.jl")
using .SimCLI

satnet(args::Vector{String}) = SimCLI.command_main(args)

end # module

module SatelliteSimJulia

using Reexport

@reexport using SatelliteSimCore
@reexport using SatelliteSimNet
@reexport using SatelliteSimOpt
@reexport using SatelliteSimSecurity
@reexport using SatelliteSimLab
@reexport using SatelliteSimTraffic
@reexport using SatelliteSimDistributed

# Visualization is intentionally not loaded by default. Use `using SatelliteSimViz`
# explicitly when plotting is needed so the core package can stay usable in
# headless CI and lightweight simulation workflows.

end # module

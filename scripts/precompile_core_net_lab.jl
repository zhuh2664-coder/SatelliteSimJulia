module SatelliteSimCoreNetLabPrecompile

using SatelliteSimCore
using SatelliteSimNet
using SatelliteSimLab

function run_workload()::Nothing
    SatelliteSimCore.LEO_DEFAULTS
    SatelliteSimCore.list_constellations()
    SatelliteSimCore.list_routing()
    SatelliteSimCore.list_traffic()
    SatelliteSimCore.list_constraints()

    SatelliteSimNet.GridPlusStrategy()
    SatelliteSimNet.DijkstraRouting()

    SatelliteSimLab.ExperimentConfig()
    SatelliteSimLab.list_goals()
    return nothing
end

run_workload()

end # module

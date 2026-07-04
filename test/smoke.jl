# Lightweight CI smoke test.
#
# This intentionally avoids loading the top-level SatelliteSimJulia package,
# because that package currently re-exports SatelliteSimViz and therefore may
# pull in GLMakie. The full suite still exercises the complete package.

push!(LOAD_PATH, "@stdlib")

using Dates
using Test
using SatelliteSimCore

@testset "smoke" begin
    epoch = SimulationEpoch(DateTime(2026, 1, 1), TimeUTC)
    grid = SimulationTimeGrid(epoch, 10, 5)

    @test time_count(grid) == 3
    @test timeslot_offsets(grid) == [0, 5, 10]

    @test :iridium in list_constellations()
    iridium = resolve_constellation(:iridium)
    @test iridium.T == 66
    @test iridium.P == 6
    @test iridium.alt_km == 780.0
end

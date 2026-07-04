# Lightweight CI smoke test.
#
# This intentionally avoids loading the top-level SatelliteSimJulia package,
# because that package currently re-exports SatelliteSimViz and therefore may
# pull in GLMakie. The full suite still exercises the complete package.

push!(LOAD_PATH, "@stdlib")

using Test
using SatelliteSimCore

@testset "smoke: time grid" begin
    epoch = default_starlink_simulation_epoch()
    grid = SimulationTimeGrid(epoch, 10, 5)

    @test time_count(grid) == 3
    @test timeslot_offsets(grid) == [0, 5, 10]

    uneven_grid = SimulationTimeGrid(epoch, 10, 3)
    @test time_count(uneven_grid) == 5
    @test timeslot_offsets(uneven_grid) == [0, 3, 6, 9, 10]
end

@testset "smoke: catalogs" begin
    constellations = list_constellations()
    @test :iridium in constellations
    @test :starlink_gen1 in constellations

    iridium = resolve_constellation(:iridium)
    @test iridium.T == 66
    @test iridium.P == 6
    @test iridium.alt_km == 780.0

    @test :dijkstra in list_routing()
    @test occursin("Dijkstra", describe_routing(:dijkstra))

    @test :uniform in list_traffic()
    @test :hotspot in list_traffic()
end

@testset "smoke: repository assets" begin
    root = normpath(joinpath(@__DIR__, ".."))
    @test isfile(joinpath(root, "Project.toml"))
    @test isfile(joinpath(root, "README.md"))
    @test isfile(joinpath(root, "config", "constellations", "Starlink.toml"))
end

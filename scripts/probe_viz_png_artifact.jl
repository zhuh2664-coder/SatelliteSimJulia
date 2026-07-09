#!/usr/bin/env julia

using Test
using SatelliteSimViz

@testset "Viz PNG artifact probe" begin
    # Probe-only internal bypass: avoids GeoMakie/NaturalEarth download noise.
    SatelliteSimViz._coastline_cache[] = :builtin
    SatelliteSimViz._coastline_source[] = :builtin

    pos = zeros(Float64, 2, 1, 3)
    pos[1, 1, :] .= (7000.0, 0.0, 0.0)
    pos[2, 1, :] .= (0.0, 7000.0, 0.0)

    config = MakieViewerConfig(;
        title="Viz PNG probe",
        time_index=1,
        show_orbits=false,
        show_ground_stations=false,
        dark_theme=false,
    )

    out = joinpath(mktempdir(), "orbit_snapshot.png")
    path = save_orbit_snapshot(out, pos; config=config)

    @test path == out
    @test isfile(path)
    @test filesize(path) > 1000
end

println("VIZ PNG ARTIFACT: ALL PASS")

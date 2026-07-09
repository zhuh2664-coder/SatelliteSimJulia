#!/usr/bin/env julia

using Dates
using Test
using SatelliteSimCore

function load_tle_elements(path::String; max_sats::Int=4)
    lines = readlines(path)
    elements = TLEOrbitElementSet[]
    i = 1
    while i + 2 <= length(lines) && length(elements) < max_sats
        push!(elements, TLEOrbitElementSet(strip(lines[i]), strip(lines[i + 1]), strip(lines[i + 2])))
        i += 3
    end
    return elements
end

@testset "Orbit real TLE unified entry" begin
    tle_path = joinpath(@__DIR__, "..", "data", "tle", "celestrak", "starlink_gp_latest.tle")
    @test isfile(tle_path)

    tles = load_tle_elements(tle_path; max_sats=4)
    @test length(tles) == 4
    @test all(tle -> startswith(tle.line1, "1 "), tles)
    @test all(tle -> startswith(tle.line2, "2 "), tles)

    grid = SimulationTimeGrid(SimulationEpoch(DateTime(2026, 6, 8, 0, 0, 0)), 120, 60)
    positions = propagate_to_ecef(
        tles,
        grid;
        propagator=Sgp4PropagatorAdapter(; verify_checksum=false),
    )

    @test size(positions) == (length(tles), time_count(grid), 3)
    @test time_count(grid) == 3
    @test all(isfinite, positions)

    radii = [sqrt(sum(positions[i, t, :].^2)) for i in 1:length(tles), t in 1:time_count(grid)]
    @test all(r -> 6_000.0 < r < 8_000.0, radii)

    satellites = [
        Satellite(id=i, name=tles[i].name, orbit=tles[i], config=SatelliteConfig())
        for i in eachindex(tles)
    ]
    eph = propagate_constellation(
        Sgp4PropagatorAdapter(; verify_checksum=false),
        satellites,
        grid,
        "starlink_real_tle_probe",
    )

    @test eph isa ConstellationEphemeris
    @test eph.constellation_name == "starlink_real_tle_probe"
    @test length(eph) == length(tles)
    @test all(i -> length(eph[i]) == time_count(grid), eachindex(tles))
    @test all(i -> all(isfinite, eph[i][1].cartesian.position_km), eachindex(tles))
end

println("ORBIT REAL TLE UNIFIED ENTRY: ALL PASS")

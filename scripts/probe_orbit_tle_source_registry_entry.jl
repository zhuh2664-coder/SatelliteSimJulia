#!/usr/bin/env julia

using Test
using Dates
using SatelliteSimFoundation
using SatelliteSimOrbit

@testset "Orbit TLE source registry entry" begin
    root = normpath(joinpath(@__DIR__, ".."))
    registry = SatelliteSimOrbit.default_tle_source_registry(project_root = root)

    ids = SatelliteSimOrbit.tle_source_ids(registry)
    @test "celestrak-starlink" in ids
    @test "spacetrack-starlink-show" in ids

    celestrak_source = SatelliteSimOrbit.resolve_tle_source(registry, "celestrak-starlink")
    @test celestrak_source isa SatelliteSimOrbit.TLETextFileSource
    @test isfile(celestrak_source.path)

    records = SatelliteSimOrbit.load_tle_records(registry, "celestrak-starlink")
    @test length(records) >= 4
    @test all(record -> startswith(record.line1, "1 "), records[1:4])
    @test all(record -> startswith(record.line2, "2 "), records[1:4])

    epoch = SimulationEpoch(DateTime(2026, 1, 1))
    grid = SimulationTimeGrid(epoch, 120, 60)
    tle_elements = [
        TLEOrbitElementSet(record.name, record.line1, record.line2)
        for record in records[1:4]
    ]
    positions = propagate_to_ecef(
        tle_elements,
        grid;
        propagator = Sgp4PropagatorAdapter(verify_checksum = false),
    )
    @test size(positions) == (4, 3, 3)
    @test all(isfinite, positions)
    radii = [sqrt(sum(abs2, positions[i, t, :])) for i in 1:4, t in 1:3]
    @test all(radius -> 6_000.0 < radius < 8_000.0, radii)

    spacetrack_records = SatelliteSimOrbit.load_tle_records(registry, "spacetrack-starlink-show")
    @test length(spacetrack_records) >= 2
    @test all(record -> !isempty(record.name), spacetrack_records[1:2])
    @test all(record -> startswith(record.line1, "1 "), spacetrack_records[1:2])
    @test all(record -> startswith(record.line2, "2 "), spacetrack_records[1:2])
end

println("ORBIT TLE SOURCE REGISTRY ENTRY: ALL PASS")

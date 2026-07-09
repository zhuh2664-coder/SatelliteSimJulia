#!/usr/bin/env julia

using Dates
using Test
using SatelliteSimCore

const VANGUARD_TLE = TLEOrbitElementSet(
    "VANGUARD 1",
    "1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753",
    "2 00005  34.2682 331.5174 1859667 331.7664  19.3264 10.82419157413667",
)

@testset "Orbit propagator matrix" begin
    @testset "J4 design constellation array entry" begin
        elems = generate_walker_delta(; T=4, P=2, F=0, alt_km=550.0, inc_deg=53.0)
        grid = SimulationTimeGrid(SimulationEpoch(DateTime(2024, 1, 1)), 120, 60)

        pos = propagate_to_ecef(elems, grid; propagator=J4Propagator())

        @test size(pos) == (4, time_count(grid), 3)
        @test time_count(grid) == 3
        @test all(isfinite, pos)

        radii = [sqrt(sum(pos[i, t, :].^2)) for i in 1:4, t in 1:time_count(grid)]
        @test all(r -> 6500.0 < r < 7500.0, radii)
    end

    @testset "SGP4 TLE bare array entry" begin
        grid = SimulationTimeGrid(SimulationEpoch(DateTime(2000, 6, 27, 18, 50, 19)), 120, 60)

        pos = propagate_to_ecef(
            [VANGUARD_TLE],
            grid;
            propagator=Sgp4PropagatorAdapter(; verify_checksum=false),
        )

        @test size(pos) == (1, time_count(grid), 3)
        @test time_count(grid) == 3
        @test all(isfinite, pos)
    end

    @testset "SGP4 ephemeris container entry" begin
        sat = Satellite(id=1, name="VANGUARD 1", orbit=VANGUARD_TLE, config=SatelliteConfig())
        grid = SimulationTimeGrid(SimulationEpoch(DateTime(2000, 6, 27, 18, 50, 19)), 120, 60)

        eph = propagate_constellation(
            Sgp4PropagatorAdapter(; verify_checksum=false),
            [sat],
            grid,
            "sgp4_tle_probe",
        )

        @test eph isa ConstellationEphemeris
        @test eph.constellation_name == "sgp4_tle_probe"
        @test length(eph) == 1
        @test length(eph[1]) == time_count(grid)
        @test eph[1].satellite_id == 1
        @test eph[1][1].time_index == 1
        @test eph[1][1].elapsed_s == 0
        @test eph[1][1].cartesian !== nothing
        @test all(isfinite, eph[1][1].cartesian.position_km)
    end
end

println("ORBIT PROPAGATOR MATRIX: ALL PASS")

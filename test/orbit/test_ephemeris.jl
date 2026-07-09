# test/orbit/test_ephemeris.jl — 星历容器不变量回归测试

using Test

const ORBIT_EPHEMERIS_ATOL = 1e-9
const ORBIT_EPHEMERIS = SatelliteSimOrbit

orbit_ephemeris_cartesian(x::Real = 7000.0) = CartesianState(ECEF, (Float64(x), 0.0, 0.0), (0.0, 7.5, 0.0))

function orbit_ephemeris_sample(
    satellite_id::Int,
    time_index::Int;
    elapsed_s::Int = (time_index - 1) * 60,
    cartesian = orbit_ephemeris_cartesian(7000.0 + 10satellite_id + time_index),
    geodetic = nothing,
)
    return EphemerisSample(
        satellite_id = satellite_id,
        time_index = time_index,
        elapsed_s = elapsed_s,
        cartesian = cartesian,
        geodetic = geodetic,
    )
end

function orbit_ephemeris_satellite(satellite_id::Int, time_count::Int = 2)
    return SatelliteEphemeris(
        satellite_id,
        [orbit_ephemeris_sample(satellite_id, time_index) for time_index in 1:time_count],
    )
end

@testset "EphemerisSample validates identifiers and position payload" begin
    cartesian = orbit_ephemeris_cartesian()
    geodetic = GeodeticPosition(10.0, 20.0, 550.0)

    cartesian_sample = EphemerisSample(
        satellite_id = 1,
        time_index = 1,
        elapsed_s = 0,
        cartesian = cartesian,
    )
    @test cartesian_sample.cartesian === cartesian
    @test cartesian_sample.geodetic === nothing

    geodetic_sample = EphemerisSample(
        satellite_id = 1,
        time_index = 1,
        elapsed_s = 0,
        geodetic = geodetic,
    )
    @test geodetic_sample.cartesian === nothing
    @test geodetic_sample.geodetic === geodetic

    both_sample = EphemerisSample(
        satellite_id = 1,
        time_index = 1,
        elapsed_s = 0,
        cartesian = cartesian,
        geodetic = geodetic,
    )
    @test both_sample.cartesian === cartesian
    @test both_sample.geodetic === geodetic

    @test_throws ArgumentError EphemerisSample(satellite_id = 0, time_index = 1, elapsed_s = 0, cartesian = cartesian)
    @test_throws ArgumentError EphemerisSample(satellite_id = 1, time_index = 0, elapsed_s = 0, cartesian = cartesian)
    @test_throws ArgumentError EphemerisSample(satellite_id = 1, time_index = 1, elapsed_s = -1, cartesian = cartesian)
    @test_throws ArgumentError EphemerisSample(satellite_id = 1, time_index = 1, elapsed_s = 0)
end

@testset "SatelliteEphemeris enforces sample ownership and order" begin
    satellite_ephemeris = orbit_ephemeris_satellite(1, 2)

    @test satellite_ephemeris.satellite_id == 1
    @test length(satellite_ephemeris) == 2
    @test satellite_ephemeris[2].time_index == 2
    @test isapprox(satellite_ephemeris[2].elapsed_s, 60; atol = ORBIT_EPHEMERIS_ATOL)

    @test_throws ArgumentError SatelliteEphemeris(0, [orbit_ephemeris_sample(1, 1)])
    @test_throws ArgumentError SatelliteEphemeris(1, EphemerisSample[])
    @test_throws ArgumentError SatelliteEphemeris(1, [orbit_ephemeris_sample(2, 1)])
    @test_throws ArgumentError SatelliteEphemeris(1, [orbit_ephemeris_sample(1, 2; elapsed_s = 60)])
end

@testset "ConstellationEphemeris preserves satellite-major sample order" begin
    grid = SimulationTimeGrid(default_starlink_simulation_epoch(), 60, 60)
    sat1 = orbit_ephemeris_satellite(1, time_count(grid))
    sat2 = orbit_ephemeris_satellite(2, time_count(grid))
    constellation = ConstellationEphemeris("mini", grid, [sat1, sat2])

    @test constellation.constellation_name == "mini"
    @test constellation.time_grid === grid
    @test length(constellation) == 2
    @test constellation[1] === sat1
    @test constellation[2] === sat2

    flattened = ephemeris_samples(constellation)
    @test [(sample.satellite_id, sample.time_index) for sample in flattened] == [
        (1, 1),
        (1, 2),
        (2, 1),
        (2, 2),
    ]

    @test_throws ArgumentError ConstellationEphemeris("", grid, [sat1])
    @test_throws ArgumentError ConstellationEphemeris("empty", grid, SatelliteEphemeris[])
    @test_throws ArgumentError ConstellationEphemeris("bad-order", grid, [sat2])
    @test_throws ArgumentError ConstellationEphemeris("bad-time", grid, [SatelliteEphemeris(1, [orbit_ephemeris_sample(1, 1)])])
end

@testset "attach_geodetic requires Cartesian source data" begin
    grid = SimulationTimeGrid(default_starlink_simulation_epoch(), 60, 60)
    geodetic_only = EphemerisSample(
        satellite_id = 1,
        time_index = 1,
        elapsed_s = 0,
        geodetic = GeodeticPosition(0.0, 0.0, 550.0),
    )

    @test_throws ArgumentError ORBIT_EPHEMERIS.attach_geodetic(geodetic_only, SimpleTemeToGeodeticTransform(), grid)
end

using Test
using Dates
using SatelliteSimStubBackend
using SatelliteSimBackends

const BACKEND = StubOrbitBackend()

const TLE_LINES = [
    "IRIDIUM 100",
    "1 42804U 17039E   23001.50000000  .00000010  00000-0  20000-4 0  9991",
    "2 42804  86.3900 260.4200 0002100 273.9700  86.0800 14.34218526  1234",
]

@testset "SatelliteSimStubBackend" begin
    @testset "parse_tle_lines" begin
        tles = parse_tle_lines(BACKEND, TLE_LINES)
        @test length(tles) == 1
        @test tles[1].name == "IRIDIUM 100"
        @test abs(tles[1].eccentricity - 0.00021) < 1e-4
    end

    @testset "propagate_sgp4" begin
        tles = parse_tle_lines(BACKEND, TLE_LINES)
        epoch = DateTime(2023, 1, 1, 12, 0, 0)
        offsets = collect(0:60:3600)
        pos = propagate_sgp4(BACKEND, tles, offsets; epoch)
        @test size(pos) == (1, 61, 3)
        r = sqrt.(pos[1, :, 1] .^ 2 .+ pos[1, :, 2] .^ 2 .+ pos[1, :, 3] .^ 2)
        @test all(6700 .< r .< 7500)
    end

    @testset "propagate_keplerian" begin
        elem = InternalKeplerianElements(
            6928e3, 0.0, deg2rad(53.0), 0.0, 0.0, 0.0,
            DateTime(2023, 1, 1, 12, 0, 0),
        )
        epoch = DateTime(2023, 1, 1, 12, 0, 0)
        pos = propagate_keplerian(BACKEND, [elem], [0, 300, 600]; epoch)
        @test size(pos) == (1, 3, 3)
    end

    @testset "teme_to_geodetic" begin
        lat, lon, alt = teme_to_geodetic(BACKEND, (6928.0, 0.0, 0.0), DateTime(2023, 1, 1, 12, 0, 0))
        @test -90 <= lat <= 90
        @test 500 < alt < 600
    end
end

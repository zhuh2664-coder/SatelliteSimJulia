push!(LOAD_PATH, "@stdlib")

using SatelliteSimJulia
using Dates
using SatelliteSimFoundation: TimeUTC, SatelliteConfig
import LinearAlgebra
using Test

# GLMakie 是 Viz 的弱依赖扩展，顶层 Project 不强制列它；
# 测试里按需可选 import，缺失时跳过 makie 相关 testset。
const HAS_GLMAKIE = try
    @eval import GLMakie
    true
catch
    false
end

struct FixturePropagator <: AbstractPropagator end

SatelliteSimJulia.supports_orbit_elements(
    ::FixturePropagator,
    ::DesignOrbitElementSet,
) = true

function SatelliteSimJulia.propagate_sample(
    ::FixturePropagator,
    satellite::Satellite,
    time_grid::SimulationTimeGrid,
    time_index::Int,
)::EphemerisSample
    elapsed_s = timeslot_offsets(time_grid)[time_index]
    state = CartesianState(
        ECI,
        (Float64(satellite.id), Float64(elapsed_s), Float64(time_index)),
        (0.0, 0.0, 0.0),
    )
    return EphemerisSample(
        satellite_id = satellite.id,
        time_index = time_index,
        elapsed_s = elapsed_s,
        cartesian = state,
    )
end

@testset "package skeleton" begin
    @test AbstractConstellationBuilder isa DataType
    @test AbstractFrameTransform isa DataType
    @test AbstractOrbitElementSet isa DataType
    @test AbstractPropagator isa DataType
end

@testset "time model" begin
    epoch = SimulationEpoch(DateTime(2026, 1, 1), TimeUTC)
    grid = SimulationTimeGrid(epoch, 10, 3)
    default_epoch = default_starlink_simulation_epoch()

    @test default_epoch.instant == DateTime(2026, 1, 1)
    @test timeslot_offsets(grid) == [0, 3, 6, 9, 10]
    @test time_count(grid) == 5
    @test_throws ArgumentError SimulationTimeGrid(epoch, -1, 3)
    @test_throws ArgumentError SimulationTimeGrid(epoch, 10, 0)
end

@testset "frames and positions" begin
    state = CartesianState(ECI, (1.0, 2.0, 3.0), (0.1, 0.2, 0.3))
    lla = GeodeticPosition(31.2, 121.5, 550.0)
    ecef_surface = CartesianState(ECEF, (6378.137, 0.0, 0.0), nothing)
    surface_lla = SatelliteSimJulia.ecef_to_geodetic(ecef_surface)

    @test state.frame == ECI
    @test lla.altitude_km == 550.0
    @test surface_lla.latitude_deg ≈ 0.0 atol = 1e-9
    @test surface_lla.longitude_deg ≈ 0.0 atol = 1e-9
    @test surface_lla.altitude_km ≈ 0.0 atol = 1e-9
    @test_throws ArgumentError GeodeticPosition(91.0, 0.0, 0.0)
    @test_throws ArgumentError GeodeticPosition(0.0, 181.0, 0.0)
    @test_throws ArgumentError SatelliteSimJulia.ecef_to_geodetic(state)
end

@testset "orbit element sets" begin
    design = DesignOrbitElementSet(
        altitude_km = 550,
        inclination_deg = 53,
        raan_deg = 10,
    )
    tle = TLEOrbitElementSet(
        "SAT",
        "1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753",
        "2 00005  34.2682 331.5174 1859667 331.7664  19.3264 10.82419157413667",
    )

    @test design isa AbstractOrbitElementSet
    @test design.altitude_km == 550.0
    @test tle isa AbstractOrbitElementSet
    @test tle.name == "SAT"
    earth_fixed = EarthFixedOrbitElementSet(
        550.0, 53.0, 10.0, 0.0, SourceMetadata("earth-fixed"),
    )
    @test earth_fixed isa AbstractOrbitElementSet
    @test earth_fixed.altitude_km == 550.0
    @test SatelliteSimOrbit.earth_fixed_node_longitude_deg(earth_fixed) ≈ 30.0
    @test_throws ArgumentError EarthFixedOrbitElementSet(-1.0, 53.0, 10.0, 0.0, SourceMetadata("x"))
end

@testset "constellation entities" begin
    metadata = SourceMetadata("unit-test")
    elements = DesignOrbitElementSet(altitude_km = 550, inclination_deg = 53, metadata = metadata)
    sat = Satellite(id = 1, orbit = elements, config = SatelliteConfig())
    plane = OrbitPlane(raan_deg = 0.0, satellites = [sat])
    shell = Shell(altitude_km = 550, inclination_deg = 53, planes = [plane])
    gs = GroundStation(1, "Shanghai", GeodeticPosition(31.2, 121.5, 0.0))

    @test sat.orbit === elements
    @test plane.satellites[1] === sat
    @test shell.planes[1] === plane
    @test gs.position.latitude_deg == 31.2
    @test sat.id == 1
end

@testset "ephemeris sample" begin
    state = CartesianState(ECEF, (1.0, 2.0, 3.0), nothing)
    sample = EphemerisSample(satellite_id = 1, time_index = 1, elapsed_s = 0, cartesian = state)
    satellite_ephemeris = SatelliteEphemeris(1, [sample])

    @test sample.cartesian === state
    @test sample.geodetic === nothing
    @test satellite_ephemeris[1] === sample
    @test_throws ArgumentError EphemerisSample(satellite_id = 1, time_index = 1, elapsed_s = 0)
    @test_throws ArgumentError SatelliteEphemeris(1, EphemerisSample[])
end

# ── 归档 API 段（StarPerf/testbed/旧 Satellite 模型等）────────────────
# 默认跳过；设 SATSIM_RUN_LEGACY_ARCHIVE=1 可尝试运行（不保证通过）。
const RUN_LEGACY_ARCHIVE = get(ENV, "SATSIM_RUN_LEGACY_ARCHIVE", "0") == "1"

if RUN_LEGACY_ARCHIVE
    include(joinpath(@__DIR__, "_runtests_legacy_archive_body.jl"))
else
    @testset "legacy archive API (skipped)" begin
        @test_skip "归档 API 未迁移；设 SATSIM_RUN_LEGACY_ARCHIVE=1 尝试运行，见 test/runtests_legacy.jl"
    end
end

# ===== 攻防对抗层测试（P0）=====
include(joinpath(@__DIR__, "test_security.jl"))

# ===== 攻防对抗层 P1 端到端测试 =====
include(joinpath(@__DIR__, "test_security_p1.jl"))

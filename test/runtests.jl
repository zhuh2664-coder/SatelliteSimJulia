# Julia ≥1.12 的 Pkg.test() 沙箱不自动包含 @stdlib 路径，
# 需要手动添加才能使 using Test 等 stdlib 正常工作。
push!(LOAD_PATH, "@stdlib")

using SatelliteSimJulia
using Dates
import LinearAlgebra
using JSON
using Printf
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
    @test AbstractEphemerisStore isa DataType
    @test AbstractFrameTransform isa DataType
    @test AbstractOrbitElementSet isa DataType
    @test AbstractPropagator isa DataType
    @test AbstractValidationCase isa DataType
end

@testset "time model" begin
    epoch = SimulationEpoch(DateTime(2026, 1, 1), TimeUTC)
    grid = SimulationTimeGrid(epoch, 10, 3)

    @test epoch.environment.earth_rotation.model == EarthRotationUniform
    @test epoch.environment.solar.model == SolarEnvironmentDisabled
    @test epoch.environment.atmosphere.model == AtmosphereEnvironmentBStarOnly
    @test epoch.environment.frame.model == FrameEnvironmentSimpleTEME
    @test simulation_epoch_year(epoch) == 26
    @test simulation_epoch_day(epoch) == 1.0

    experiment_environment = EpochEnvironment(
        earth_rotation = EarthRotationEnvironment(model = EarthRotationIERS),
        solar = SolarEnvironment(model = SolarEnvironmentAnalytic, include_eclipse = true),
        atmosphere = AtmosphereEnvironment(model = AtmosphereEnvironmentSpaceWeather, f107 = 120, ap = 8),
        frame = FrameEnvironment(model = FrameEnvironmentIERS, ut1_utc_s = 0.1),
    )
    experiment_epoch = SimulationEpoch(DateTime(2026, 1, 1), TimeUTC, experiment_environment)
    default_epoch = default_starlink_simulation_epoch()

    @test experiment_epoch.environment.earth_rotation.model == EarthRotationIERS
    @test experiment_epoch.environment.solar.include_eclipse
    @test experiment_epoch.environment.atmosphere.f107 == 120.0
    @test experiment_epoch.environment.frame.ut1_utc_s == 0.1
    @test default_epoch.instant == DateTime(2026, 1, 1)
    @test default_epoch.system == TimeUTC
    @test timeslot_offsets(grid) == [0, 3, 6, 9, 10]
    @test time_count(grid) == 5
    @test_throws ArgumentError EarthRotationEnvironment(reference_rate_rad_s = 0)
    @test_throws ArgumentError SolarEnvironment(solar_constant_w_m2 = 0)
    @test_throws ArgumentError AtmosphereEnvironment(f107 = -1)
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
        mean_anomaly_deg = 20,
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
        altitude_km = 550,
        inclination_deg = 53,
        raan_deg = 10,
        mean_anomaly_deg = 20,
    )
    @test earth_fixed isa AbstractOrbitElementSet
    @test earth_fixed.altitude_km == 550.0
    @test earth_fixed.mean_motion_rev_per_day ≈ EARTH_FIXED_ROTATION_REV_PER_DAY
    @test earth_fixed_node_longitude_deg(earth_fixed) ≈ 30.0
    @test_throws ArgumentError DesignOrbitElementSet(altitude_km = -1, inclination_deg = 53)
    @test_throws ArgumentError EarthFixedOrbitElementSet(altitude_km = -1)
    @test_throws ArgumentError EarthFixedOrbitElementSet(inclination_deg = 91)
    @test_throws ArgumentError EarthFixedOrbitElementSet(eccentricity = 0.1)
    @test_throws ArgumentError TLEOrbitElementSet("bad", "x", "2 ok")
end

@testset "constellation entities" begin
    metadata = SourceMetadata("unit-test")
    elements = DesignOrbitElementSet(altitude_km = 550, inclination_deg = 53, metadata = metadata)
    identifier = SatelliteId(
        global_id = 1,
        shell_id = 1,
        shell_local_id = 1,
        orbit_plane_id = 1,
        plane_local_slot = 1,
    )
    sat = Satellite(
        identifier = identifier,
        orbit_elements = elements,
    )
    plane = OrbitPlane(1, 1, 0, [sat])
    shell = Shell(id = 1, name = "shell1", altitude_km = 550, inclination_deg = 53, orbit_planes = [plane])
    constellation = Constellation("Starlink", [shell], metadata)
    gs = GroundStation(1, "Shanghai", GeodeticPosition(31.2, 121.5, 0.0))

    @test sat.orbit_elements === elements
    @test plane.satellites[1] === sat
    @test shell.orbit_planes[1] === plane
    @test constellation.shells[1] === shell
    @test gs.position.latitude_deg == 31.2
    @test sat.id == 1
    @test global_satellite_id(sat) == 1
    @test shell_local_satellite_id(sat) == 1
    @test orbit_plane_id(sat) == 1
    @test plane_local_slot(sat) == 1
    @test_throws ArgumentError SatelliteId(
        global_id = 0,
        shell_id = 1,
        shell_local_id = 1,
        orbit_plane_id = 1,
        plane_local_slot = 1,
    )
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

@testset "satellite runtime states" begin
    power = PowerState(
        battery_capacity_wh = 1000,
        stored_energy_wh = 750,
        solar_generation_w = 120,
        base_load_w = 30,
        payload_load_w = 20,
        communication_load_w = 10,
    )
    communication = CommunicationTailState(
        downlink_tail_remaining = 2,
        uplink_tail_remaining = 1,
        isl_sender_tail_remaining = 3,
        isl_receiver_tail_remaining = 0,
    )
    state = SatelliteRuntimeState(
        satellite_id = 1,
        status = SatelliteDegraded,
        power = power,
        communication = communication,
    )
    table = SatelliteStateTable(3)

    @test state.status == SatelliteDegraded
    @test total_load_w(power) == 60.0
    @test state_of_charge(power) == 0.75
    @test is_operational(state)
    @test length(table) == 3
    @test table[2].satellite_id == 2
    @test runtime_state(table, 3).status == SatelliteNominal

    set_runtime_state!(table, state)
    @test table[1] === state

    updated_power = PowerState(
        battery_capacity_wh = 1000,
        stored_energy_wh = 700,
        base_load_w = 30,
    )
    update_power_state!(table, 1, updated_power)
    @test table[1].power === updated_power
    @test table[1].communication === communication

    updated_communication = CommunicationTailState(downlink_tail_remaining = 1)
    update_communication_tail_state!(table, 1, updated_communication)
    @test table[1].communication === updated_communication
    @test table[1].power === updated_power

    offline_state = SatelliteRuntimeState(satellite_id = 2, status = SatelliteOffline)
    @test !is_operational(offline_state)
    @test state_of_charge(PowerState()) === nothing
    @test_throws ArgumentError PowerState(battery_capacity_wh = 10, stored_energy_wh = 11)
    @test_throws ArgumentError CommunicationTailState(downlink_tail_remaining = -1)
    @test_throws ArgumentError SatelliteRuntimeState(satellite_id = 0)
    @test_throws ArgumentError SatelliteStateTable([
        SatelliteRuntimeState(satellite_id = 2),
    ])
end

@testset "constellation specs" begin
    spec_path = joinpath(@__DIR__, "..", "config", "constellations", "Starlink.toml")
    spec = load_constellation_spec(spec_path)

    @test spec.name == "Starlink"
    @test length(spec.shells) == 4
    @test spec.shells[1].altitude_km == 550.0
    @test spec.shells[1].orbit_count == 72
    @test spec.shells[1].satellites_per_orbit == 22
    @test spec.shells[3].inclination_deg == 97.6
    @test sum(shell.orbit_count * shell.satellites_per_orbit for shell in spec.shells) == 4408

    @test_throws ArgumentError design_shell_input(
        id = 1,
        name = "bad",
        altitude_km = -1,
        inclination_deg = 53,
        phase_shift = 1,
        orbit_count = 72,
        satellites_per_orbit = 22,
    )
    @test_throws ArgumentError ConstellationSpec("Bad", "test", NamedTuple[])
end

@testset "design constellation builder" begin
    spec_path = joinpath(@__DIR__, "..", "config", "constellations", "Starlink.toml")
    spec = load_constellation_spec(spec_path)
    constellation = build_constellation(spec, DesignConstellationBuilder("StarPerf design spec"))

    @test constellation.name == "Starlink"
    @test length(constellation.shells) == 4

    shell1 = constellation.shells[1]
    @test length(shell1.orbit_planes) == 72
    @test sum(length(plane.satellites) for plane in shell1.orbit_planes) == 1584
    @test shell1.orbit_planes[1].raan_deg == 0.0
    @test shell1.orbit_planes[2].raan_deg == 5.0

    shell3 = constellation.shells[3]
    @test length(shell3.orbit_planes) == 10
    @test shell3.orbit_planes[2].raan_deg == 18.0

    satellites = [
        sat for shell in constellation.shells
        for plane in shell.orbit_planes
        for sat in plane.satellites
    ]
    @test length(satellites) == 4408
    @test [sat.id for sat in satellites] == collect(1:4408)
    @test [global_satellite_id(sat) for sat in satellites] == collect(1:4408)
    @test satellite_count(constellation) == 4408
    @test validate_satellite_ids(constellation)

    first_sat = satellites[1]
    @test first_sat.identifier.shell_id == 1
    @test first_sat.identifier.shell_local_id == 1
    @test first_sat.identifier.orbit_plane_id == 1
    @test first_sat.identifier.plane_local_slot == 1
    @test first_sat.orbit_elements isa DesignOrbitElementSet
    @test first_sat.orbit_elements.altitude_km == 550.0
    @test first_sat.orbit_elements.inclination_deg == 53.0
    @test first_sat.orbit_elements.raan_deg == 0.0
    @test first_sat.orbit_elements.mean_anomaly_deg == 0.0

    shifted_sat = shell1.orbit_planes[2].satellites[1]
    @test shifted_sat.identifier.global_id == 23
    @test shifted_sat.identifier.shell_local_id == 23
    @test shifted_sat.identifier.orbit_plane_id == 2
    @test shifted_sat.identifier.plane_local_slot == 1
    @test shifted_sat.orbit_elements.mean_anomaly_deg ≈ 360.0 / (72 * 22)

    shell2_first_sat = constellation.shells[2].orbit_planes[1].satellites[1]
    @test shell2_first_sat.identifier.global_id == 1585
    @test shell2_first_sat.identifier.shell_local_id == 1
    @test shell2_first_sat.identifier.orbit_plane_id == 1
    @test shell2_first_sat.identifier.plane_local_slot == 1

    state_table = SatelliteStateTable(constellation)
    @test length(state_table) == satellite_count(constellation)
    @test state_table[first_sat].satellite_id == first_sat.id
    @test state_table[shell2_first_sat].satellite_id == 1585
end

@testset "tle constellation builder" begin
    tle_text = """
    VANGUARD 1
    1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753
    2 00005  34.2682 331.5174 1859667 331.7664  19.3264 10.82419157413661
    TEST SAT
    1 00006U 58002C   00179.78495062  .00000023  00000-0  28098-4 0  4754
    2 00006  34.2682 331.5174 1859667 331.7664  19.3264 10.82419157413662
    """
    records = parse_tle_records(tle_text)
    spec = TLEConstellationSpec("TLEFixture", "unit-test", records)
    constellation = build_constellation(spec, TLEConstellationBuilder("unit-test tle"))

    @test length(records) == 2
    @test records[1].name == "VANGUARD 1"
    @test spec.shells[1].name == "shell1"
    @test constellation.name == "TLEFixture"
    @test length(constellation.shells) == 1
    @test length(constellation.shells[1].orbit_planes) == 1
    @test satellite_count(constellation) == 2
    @test validate_satellite_ids(constellation)

    satellites = SatelliteSimJulia.satellites(constellation)
    @test satellites[1].name == "VANGUARD 1"
    @test satellites[2].identifier.global_id == 2
    @test satellites[2].identifier.shell_local_id == 2
    @test satellites[2].identifier.orbit_plane_id == 1
    @test satellites[2].identifier.plane_local_slot == 2
    @test satellites[1].orbit_elements isa TLEOrbitElementSet
    @test satellites[1].orbit_elements.name == "VANGUARD 1"
    @test supports_orbit_elements(Sgp4PropagatorAdapter(), satellites[1].orbit_elements)

    unnamed_text = """
    1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753
    2 00005  34.2682 331.5174 1859667 331.7664  19.3264 10.82419157413661
    """
    unnamed_path = tempname()
    write(unnamed_path, unnamed_text)
    loaded_spec = load_tle_constellation_spec(
        unnamed_path;
        name = "LoadedTLE",
        shell_name = "tle-shell",
        default_name_prefix = "AUTO",
    )
    @test loaded_spec.name == "LoadedTLE"
    @test loaded_spec.shells[1].name == "tle-shell"
    @test loaded_spec.shells[1].records[1].name == "AUTO-1"

    text_source_path = tempname()
    write(text_source_path, unnamed_text)
    text_source = TLETextFileSource(
        "fixture-text",
        text_source_path;
        default_name_prefix = "AUTO",
        verify_with_juliaspace = true,
    )
    registry = TLESourceRegistry()
    register_tle_source!(registry, text_source)

    @test tle_source_id(text_source) == "fixture-text"
    @test tle_source_ids(registry) == ["fixture-text"]
    @test resolve_tle_source(registry, "fixture-text") === text_source
    @test load_tle_records(text_source)[1].name == "AUTO-1"
    @test load_tle_records(registry, "fixture-text")[1].name == "AUTO-1"

    starperf_path = tempname()
    open(starperf_path, "w") do io
        JSON.print(
            io,
            [
                Dict(
                    "OBJECT_NAME" => "STARLINK-TEST",
                    "OBJECT_ID" => "2019-074A",
                    "EPOCH" => "2024-05-20T13:33:20.193",
                    "MEAN_MOTION" => 15.06388316,
                    "ECCENTRICITY" => 0.0001793,
                    "INCLINATION" => 53.0548,
                    "RA_OF_ASC_NODE" => 261.0513,
                    "ARG_OF_PERICENTER" => 106.2162,
                    "MEAN_ANOMALY" => 253.9024,
                    "CLASSIFICATION_TYPE" => "U",
                    "NORAD_CAT_ID" => 44713,
                    "ELEMENT_SET_NO" => 999,
                    "REV_AT_EPOCH" => 24955,
                    "BSTAR" => 0.00031796,
                    "MEAN_MOTION_DOT" => 4.456e-5,
                    "MEAN_MOTION_DDOT" => 0,
                ),
            ],
        )
    end
    starperf_source = StarPerfTLEJsonSource("fixture-starperf", starperf_path)
    starperf_records = load_tle_records(starperf_source)
    starperf_elements = SatelliteSimJulia.parse_tle_record_elements(
        starperf_records[1];
        verify_checksum = false,
    )

    @test starperf_records[1].name == "STARLINK-TEST"
    @test startswith(starperf_records[1].line1, "1 ")
    @test startswith(starperf_records[1].line2, "2 ")
    @test starperf_elements.inclination_deg ≈ 53.0548 atol = 1e-4
    @test starperf_elements.raan_deg ≈ 261.0513 atol = 1e-4
    @test starperf_elements.mean_motion_rev_per_day ≈ 15.06388316 atol = 1e-8

    default_registry = default_tle_source_registry(project_root = Base.pkgdir(SatelliteSimJulia))
    @test "celestrak-starlink" in tle_source_ids(default_registry)
    @test "starperf-starlink-json" in tle_source_ids(default_registry)

    @test_throws ArgumentError parse_tle_records("")
    @test_throws ArgumentError parse_tle_records("BAD NAME\n1 bad")
    @test_throws ArgumentError resolve_tle_source(registry, "missing")
    @test_throws ArgumentError TLEShellSpec(id = 1, name = "empty", records = TLERecordSpec[])
end

@testset "tle orbit plane grouping builder" begin
    function tle_line2(satnum::Int, inclination::Real, raan::Real, argp::Real, mean_anomaly::Real)
        return @sprintf(
            "2 %05d %8.4f %8.4f 0001000 %8.4f %8.4f 15.00000000000000",
            satnum,
            inclination,
            raan,
            argp,
            mean_anomaly,
        )
    end

    base_line1(satnum::Int) = @sprintf(
        "1 %05dU 58002B   00179.78495062  .00000023  00000-0  28098-4 0  0000",
        satnum,
    )

    records = TLERecordSpec[]
    push!(records, TLERecordSpec("P1-S3", base_line1(101), tle_line2(101, 53.0, 359.8, 0, 240)))
    push!(records, TLERecordSpec("P2-S2", base_line1(102), tle_line2(102, 53.0, 119.7, 0, 120)))
    push!(records, TLERecordSpec("P1-S1", base_line1(103), tle_line2(103, 53.0, 0.1, 0, 0)))
    push!(records, TLERecordSpec("P3-S2", base_line1(104), tle_line2(104, 53.0, 240.3, 0, 120)))
    push!(records, TLERecordSpec("P2-S3", base_line1(105), tle_line2(105, 53.0, 120.2, 0, 240)))
    push!(records, TLERecordSpec("P3-S1", base_line1(106), tle_line2(106, 53.0, 239.9, 0, 0)))
    push!(records, TLERecordSpec("P1-S2", base_line1(107), tle_line2(107, 53.0, 0.4, 0, 120)))
    push!(records, TLERecordSpec("P2-S1", base_line1(108), tle_line2(108, 53.0, 119.9, 0, 0)))
    push!(records, TLERecordSpec("P3-S3", base_line1(109), tle_line2(109, 53.0, 240.1, 0, 240)))

    spec = TLEConstellationSpec("GroupedTLE", "unit-test", records)
    builder = TLEOrbitPlaneGroupingBuilder(
        config = TLEOrbitPlaneGroupingConfig(expected_planes = 3, verify_checksum = false),
    )
    constellation = build_constellation(spec, builder)

    @test length(constellation.shells) == 1
    shell = constellation.shells[1]
    @test length(shell.orbit_planes) == 3
    @test satellite_count(shell) == 9
    @test validate_satellite_ids(constellation)

    plane_names = [[sat.name for sat in plane.satellites] for plane in shell.orbit_planes]
    @test plane_names[1] == ["P1-S1", "P1-S2", "P1-S3"]
    @test plane_names[2] == ["P2-S1", "P2-S2", "P2-S3"]
    @test plane_names[3] == ["P3-S1", "P3-S2", "P3-S3"]
    @test [plane_local_slot(sat) for sat in shell.orbit_planes[1].satellites] == [1, 2, 3]
    @test [orbit_plane_id(sat) for sat in shell.orbit_planes[2].satellites] == [2, 2, 2]
    @test [global_satellite_id(sat) for sat in satellites(constellation)] == collect(1:9)
    @test shell.inclination_deg ≈ 53.0

    inferred = build_constellation(
        spec,
        TLEOrbitPlaneGroupingBuilder(
            config = TLEOrbitPlaneGroupingConfig(verify_checksum = false),
        ),
    )
    @test length(inferred.shells[1].orbit_planes) == 3

    sparse_records = TLERecordSpec[]
    push!(sparse_records, TLERecordSpec("A-1", base_line1(201), tle_line2(201, 53.0, 0.0, 0, 0)))
    push!(sparse_records, TLERecordSpec("A-2", base_line1(202), tle_line2(202, 53.0, 0.2, 0, 120)))
    push!(sparse_records, TLERecordSpec("B-1", base_line1(203), tle_line2(203, 53.0, 120.0, 0, 0)))
    push!(sparse_records, TLERecordSpec("B-2", base_line1(204), tle_line2(204, 53.0, 120.2, 0, 120)))
    push!(sparse_records, TLERecordSpec("C-1", base_line1(205), tle_line2(205, 53.0, 240.0, 0, 0)))
    sparse_spec = TLEConstellationSpec("SparseGroupedTLE", "unit-test", sparse_records)
    sparse_builder = TLEOrbitPlaneGroupingBuilder(
        config = TLEOrbitPlaneGroupingConfig(
            expected_planes = 3,
            verify_checksum = false,
            plane_count_warning_ratio = 0.75,
        ),
    )
    @test_logs (:warn, r"below the shell average") build_constellation(sparse_spec, sparse_builder)

    quiet_sparse_builder = TLEOrbitPlaneGroupingBuilder(
        config = TLEOrbitPlaneGroupingConfig(
            expected_planes = 3,
            verify_checksum = false,
            warn_unbalanced_planes = false,
        ),
    )
    quiet_sparse = build_constellation(sparse_spec, quiet_sparse_builder)
    @test satellite_count(quiet_sparse) == 5

    @test_throws ArgumentError TLEOrbitPlaneGroupingConfig(expected_planes = 0)
    @test_throws ArgumentError TLEOrbitPlaneGroupingConfig(min_satellites_per_plane = 0)
    @test_throws ArgumentError TLEOrbitPlaneGroupingConfig(plane_count_warning_ratio = 0)
    @test_throws ArgumentError TLEOrbitPlaneGroupingConfig(plane_count_warning_ratio = 1.1)
end

@testset "static topology builder" begin
    spec = ConstellationSpec(
        "TopologyFixture",
        "unit-test",
        [
            design_shell_input(
                id = 1,
                name = "shell1",
                altitude_km = 550,
                inclination_deg = 53,
                phase_shift = 0,
                orbit_count = 2,
                satellites_per_orbit = 3,
            ),
        ],
    )
    constellation = build_constellation(spec, DesignConstellationBuilder("unit-test"))
    topology = build_topology(constellation, StaticISLTopologyBuilder())

    @test topology isa ConstellationTopology
    @test link_count(topology) == 9
    @test all(link.endpoint_a.satellite_id isa SatelliteId for link in topology_links(topology))
    @test all(link.endpoint_b.satellite_id isa SatelliteId for link in topology_links(topology))
    @test all(link.link_type isa InterSatelliteLink for link in topology_links(topology))
    @test all(link.state isa LinkAvailable for link in topology_links(topology))

    first_satellite = satellites(constellation)[1]
    @test sort(neighboring_satellite_ids(topology, first_satellite)) == [2, 3, 4]
    @test length(link_ids_for_satellite(topology, first_satellite)) == 3

    configured_builder = StaticISLTopologyBuilder(
        StaticISLTopologyConfig(
            inter_plane = InterPlaneConnectionRule(slot_offset = 1),
            default_delay_s = 0.025,
            default_capacity_mbps = 20_000,
        ),
    )
    shifted_topology = build_topology(constellation, configured_builder)
    @test sort(neighboring_satellite_ids(shifted_topology, first_satellite)) == [2, 3, 5]
    @test all(link.delay_s == 0.025 for link in topology_links(shifted_topology))
    @test all(link.capacity_mbps == 20_000 for link in topology_links(shifted_topology))

    intra_only = build_topology(
        constellation,
        StaticISLTopologyBuilder(
            StaticISLTopologyConfig(inter_plane = InterPlaneConnectionRule(enabled = false)),
        ),
    )
    @test link_count(intra_only) == 6
    @test sort(neighboring_satellite_ids(intra_only, first_satellite)) == [2, 3]

    no_slot_wrap = build_topology(
        constellation,
        StaticISLTopologyBuilder(
            StaticISLTopologyConfig(
                intra_plane = IntraPlaneConnectionRule(wrap_slots = false),
                inter_plane = InterPlaneConnectionRule(enabled = false),
            ),
        ),
    )
    @test link_count(no_slot_wrap) == 4
    @test sort(neighboring_satellite_ids(no_slot_wrap, first_satellite)) == [2]

    @test_throws ArgumentError SatelliteLink(
        id = 1,
        endpoint_a = LinkEndpoint(first_satellite),
        endpoint_b = LinkEndpoint(first_satellite),
    )
    @test_throws ArgumentError IntraPlaneConnectionRule(neighbor_slot_span = -1)
    @test_throws ArgumentError InterPlaneConnectionRule(neighbor_plane_span = -1)
    @test_throws ArgumentError StaticISLTopologyConfig(default_delay_s = -1)
end

@testset "isl physical links" begin
    metadata = SourceMetadata("unit-test")
    elements = DesignOrbitElementSet(altitude_km = 550, inclination_deg = 53, metadata = metadata)
    sat1 = Satellite(
        identifier = SatelliteId(
            global_id = 1,
            shell_id = 1,
            shell_local_id = 1,
            orbit_plane_id = 1,
            plane_local_slot = 1,
        ),
        orbit_elements = elements,
    )
    sat2 = Satellite(
        identifier = SatelliteId(
            global_id = 2,
            shell_id = 1,
            shell_local_id = 2,
            orbit_plane_id = 1,
            plane_local_slot = 2,
        ),
        orbit_elements = elements,
    )
    sat3 = Satellite(
        identifier = SatelliteId(
            global_id = 3,
            shell_id = 1,
            shell_local_id = 3,
            orbit_plane_id = 1,
            plane_local_slot = 3,
        ),
        orbit_elements = elements,
    )
    link12 = SatelliteLink(id = 1, endpoint_a = LinkEndpoint(sat1), endpoint_b = LinkEndpoint(sat2))
    link13 = SatelliteLink(id = 2, endpoint_a = LinkEndpoint(sat1), endpoint_b = LinkEndpoint(sat3))
    topology = ConstellationTopology("PhysicalFixture", [link12, link13])
    time_grid = SimulationTimeGrid(SimulationEpoch(DateTime(2026, 1, 1), TimeUTC), 0, 1)

    sample1 = EphemerisSample(
        satellite_id = 1,
        time_index = 1,
        elapsed_s = 0,
        cartesian = CartesianState(ECEF, (7000.0, 0.0, 0.0), nothing),
    )
    sample2 = EphemerisSample(
        satellite_id = 2,
        time_index = 1,
        elapsed_s = 0,
        cartesian = CartesianState(ECEF, (7000.0, 1000.0, 0.0), nothing),
    )
    sample3 = EphemerisSample(
        satellite_id = 3,
        time_index = 1,
        elapsed_s = 0,
        cartesian = CartesianState(ECEF, (-7000.0, 0.0, 0.0), nothing),
    )
    ephemeris = ConstellationEphemeris(
        "PhysicalFixture",
        time_grid,
        [
            SatelliteEphemeris(1, [sample1]),
            SatelliteEphemeris(2, [sample2]),
            SatelliteEphemeris(3, [sample3]),
        ],
    )

    @test distance_km(sample1, sample2) ≈ 1000.0
    @test propagation_delay_s(1000.0) ≈ 1000.0 / 299_792.458
    @test line_of_sight_clear([7000.0, 0.0, 0.0], [7000.0, 1000.0, 0.0])
    @test !line_of_sight_clear([7000.0, 0.0, 0.0], [-7000.0, 0.0, 0.0])

    series = evaluate_isl_physical_links(
        topology,
        ephemeris;
        config = ISLPhysicalLinkConfig(capacity_mbps = 10_000),
    )
    samples = link_samples_at(series, 1)
    @test length(samples) == 2
    @test samples[1].state isa LinkAvailable
    @test samples[1].distance_km ≈ 1000.0
    @test samples[1].capacity_mbps == 10_000
    @test samples[2].state isa LinkUnavailable
    @test !samples[2].line_of_sight
    @test samples[2].capacity_mbps == 0.0
    @test available_link_samples(series, 1) == [samples[1]]

    range_limited = evaluate_isl_physical_links(
        topology,
        ephemeris;
        config = ISLPhysicalLinkConfig(max_range_km = 900, require_line_of_sight = false),
    )
    @test all(sample.state isa LinkUnavailable for sample in link_samples_at(range_limited, 1))

    @test_throws ArgumentError ISLPhysicalLinkConfig(max_range_km = 0)
    @test_throws ArgumentError ISLPhysicalLinkConfig(earth_radius_km = 0)
    @test_throws ArgumentError ISLPhysicalLinkConfig(capacity_mbps = -1)
end

@testset "gsl physical links" begin
    time_grid = SimulationTimeGrid(SimulationEpoch(DateTime(2026, 1, 1), TimeUTC), 0, 1)
    overhead = EphemerisSample(
        satellite_id = 1,
        time_index = 1,
        elapsed_s = 0,
        cartesian = CartesianState(ECEF, (WGS84_EQUATORIAL_RADIUS_KM + 550.0, 0.0, 0.0), nothing),
    )
    hidden = EphemerisSample(
        satellite_id = 2,
        time_index = 1,
        elapsed_s = 0,
        cartesian = CartesianState(ECEF, (0.0, WGS84_EQUATORIAL_RADIUS_KM + 550.0, 0.0), nothing),
    )
    ephemeris = ConstellationEphemeris(
        "GSLFixture",
        time_grid,
        [
            SatelliteEphemeris(1, [overhead]),
            SatelliteEphemeris(2, [hidden]),
        ],
    )
    ground_station = GroundStation(1, "Equator", GeodeticPosition(0.0, 0.0, 0.0))

    ground_ecef = geodetic_to_ecef_km(ground_station.position)
    @test ground_ecef[1] ≈ WGS84_EQUATORIAL_RADIUS_KM atol = 1e-6
    @test ground_ecef[2] ≈ 0.0 atol = 1e-9
    @test elevation_deg(ground_station.position, collect(overhead.cartesian.position_km)) ≈ 90.0 atol = 1e-9
    @test elevation_deg(ground_station.position, collect(hidden.cartesian.position_km)) < 0

    series = evaluate_gsl_physical_links(
        ground_station,
        ephemeris;
        config = GSLPhysicalLinkConfig(min_elevation_deg = 25, capacity_mbps = 500),
    )
    samples = gsl_samples_at(series, 1)
    @test length(samples) == 2
    @test samples[1].state isa LinkAvailable
    @test samples[1].distance_km ≈ 550.0 atol = 1e-6
    @test samples[1].propagation_delay_s ≈ 550.0 / 299_792.458
    @test samples[1].capacity_mbps == 500
    @test samples[2].state isa LinkUnavailable
    @test samples[2].capacity_mbps == 0.0
    @test available_gsl_samples(series, 1) == [samples[1]]

    range_limited = evaluate_gsl_physical_links(
        ground_station,
        ephemeris;
        config = GSLPhysicalLinkConfig(min_elevation_deg = -90, max_range_km = 500),
    )
    @test all(sample.state isa LinkUnavailable for sample in gsl_samples_at(range_limited, 1))

    terminal = UserTerminal(2, "User", GeodeticPosition(0.0, 0.0, 0.0))
    terminal_series = evaluate_gsl_physical_links(
        terminal,
        ephemeris;
        config = GSLPhysicalLinkConfig(min_elevation_deg = 25),
    )
    @test terminal_series.ground_id == terminal.id

    fixed_model = FixedGSLCapacityModel(750)
    @test gsl_capacity_mbps(fixed_model, -10) == 750

    piecewise_model = ElevationPiecewiseGSLCapacityModel(
        base_capacity_mbps = 1000,
        cutoff_elevation_deg = 25,
        saturation_elevation_deg = 45,
        signaling_capacity_mbps = 50,
    )
    @test gsl_capacity_mbps(piecewise_model, 10) == 50
    @test gsl_capacity_mbps(piecewise_model, 25) == 50
    @test gsl_capacity_mbps(piecewise_model, 35) ≈ 525
    @test gsl_capacity_mbps(piecewise_model, 45) == 1000
    @test gsl_capacity_mbps(piecewise_model, 80) == 1000

    exponential_model = ElevationExponentialGSLCapacityModel(
        base_capacity_mbps = 1000,
        cutoff_elevation_deg = 25,
        growth_rate = 0.1,
        signaling_capacity_mbps = 25,
    )
    @test gsl_capacity_mbps(exponential_model, 20) == 25
    @test gsl_capacity_mbps(exponential_model, 25) == 25
    @test 25 < gsl_capacity_mbps(exponential_model, 45) < 1000
    @test gsl_capacity_mbps(exponential_model, 90) <= 1000

    dynamic_capacity = evaluate_gsl_physical_links(
        ground_station,
        ephemeris;
        config = GSLPhysicalLinkConfig(
            min_elevation_deg = 25,
            capacity_model = piecewise_model,
        ),
    )
    @test gsl_samples_at(dynamic_capacity, 1)[1].capacity_mbps == 1000

    @test_throws ArgumentError GSLPhysicalLinkConfig(min_elevation_deg = 91)
    @test_throws ArgumentError GSLPhysicalLinkConfig(max_range_km = 0)
    @test_throws ArgumentError GSLPhysicalLinkConfig(capacity_mbps = -1)
    @test_throws ArgumentError GSLPhysicalLinkConfig(
        capacity_mbps = 1,
        capacity_model = FixedGSLCapacityModel(1),
    )
    @test_throws ArgumentError ElevationPiecewiseGSLCapacityModel(
        base_capacity_mbps = 1000,
        cutoff_elevation_deg = 45,
        saturation_elevation_deg = 25,
    )
    @test_throws ArgumentError ElevationExponentialGSLCapacityModel(
        base_capacity_mbps = 1000,
        growth_rate = 0,
    )
end

@testset "gsl access selection" begin
    time_grid = SimulationTimeGrid(SimulationEpoch(DateTime(2026, 1, 1), TimeUTC), 20, 10)

    function gsl_sample(;
        satellite_id,
        time_index,
        distance_km,
        elevation_deg,
        capacity_mbps,
        available = true,
    )
        return GSLPhysicalLinkSample(
            ground_id = 1,
            satellite_id = satellite_id,
            time_index = time_index,
            elapsed_s = timeslot_offsets(time_grid)[time_index],
            distance_km = distance_km,
            propagation_delay_s = propagation_delay_s(distance_km),
            elevation_deg = elevation_deg,
            capacity_mbps = capacity_mbps,
            state = available ? LinkAvailable() : LinkUnavailable(),
        )
    end

    samples_by_time = [
        [
            gsl_sample(satellite_id = 1, time_index = 1, distance_km = 600, elevation_deg = 70, capacity_mbps = 800),
            gsl_sample(satellite_id = 2, time_index = 1, distance_km = 800, elevation_deg = 55, capacity_mbps = 900),
        ],
        [
            gsl_sample(satellite_id = 1, time_index = 2, distance_km = 650, elevation_deg = 68, capacity_mbps = 800),
            gsl_sample(satellite_id = 2, time_index = 2, distance_km = 590, elevation_deg = 72, capacity_mbps = 900),
        ],
        [
            gsl_sample(satellite_id = 1, time_index = 3, distance_km = 700, elevation_deg = 64, capacity_mbps = 800),
            gsl_sample(satellite_id = 2, time_index = 3, distance_km = 580, elevation_deg = 75, capacity_mbps = 900),
        ],
    ]
    series = GSLPhysicalLinkSeries(1, time_grid, samples_by_time)

    @test access_score(NearestAccessPolicy(), samples_by_time[1][1]) == -600
    @test access_score(StarPerfNearestAccessPolicy(), samples_by_time[1][1]) == -600
    @test access_score(MaxElevationAccessPolicy(), samples_by_time[1][1]) == 70
    @test access_score(MaxCapacityAccessPolicy(), samples_by_time[1][2]) == 900
    @test access_score(MinDelayAccessPolicy(), samples_by_time[1][1]) ≈ -600 / 299_792.458

    nearest = evaluate_access(NearestAccessPolicy(), series)
    starperf_nearest = evaluate_access(StarPerfNearestAccessPolicy(), series)
    @test [decision.selected_satellite_id for decision in nearest.decisions] == [1, 2, 2]
    @test [decision.selected_satellite_id for decision in starperf_nearest.decisions] == [1, 2, 2]
    @test [decision.reason for decision in starperf_nearest.decisions] == [
        :initial_access,
        :handover,
        :stay,
    ]
    @test [decision.reason for decision in nearest.decisions] == [
        :initial_access,
        :handover,
        :stay,
    ]
    @test access_decisions_at(nearest, 2).switched
    @test access_decisions_at(nearest, 2).selected_sample.satellite_id == 2

    hysteresis = evaluate_access(
        HysteresisAccessPolicy(NearestAccessPolicy(), margin = 0, time_to_trigger_s = 10),
        series,
    )
    @test [decision.selected_satellite_id for decision in hysteresis.decisions] == [1, 1, 2]
    @test hysteresis.decisions[2].reason == :handover_pending
    @test hysteresis.decisions[2].candidate_satellite_id == 2
    @test hysteresis.decisions[3].reason == :handover
    @test hysteresis.decisions[3].switched

    unavailable_series = GSLPhysicalLinkSeries(
        1,
        time_grid,
        [
            [gsl_sample(satellite_id = 1, time_index = 1, distance_km = 600, elevation_deg = 70, capacity_mbps = 800)],
            [gsl_sample(satellite_id = 1, time_index = 2, distance_km = 600, elevation_deg = 70, capacity_mbps = 800, available = false)],
            [gsl_sample(satellite_id = 1, time_index = 3, distance_km = 600, elevation_deg = 70, capacity_mbps = 800, available = false)],
        ],
    )
    unavailable = evaluate_access(NearestAccessPolicy(), unavailable_series)
    @test unavailable.decisions[1].selected_satellite_id == 1
    @test unavailable.decisions[2].selected_satellite_id === nothing
    @test unavailable.decisions[2].reason == :no_available_satellite

    function remap_gsl_sample(
        sample::GSLPhysicalLinkSample;
        ground_id::Int,
        time_index::Int = sample.time_index,
        elapsed_s::Int = sample.elapsed_s,
    )
        return GSLPhysicalLinkSample(
            ground_id = ground_id,
            satellite_id = sample.satellite_id,
            time_index = time_index,
            elapsed_s = elapsed_s,
            distance_km = sample.distance_km,
            propagation_delay_s = sample.propagation_delay_s,
            elevation_deg = sample.elevation_deg,
            capacity_mbps = sample.capacity_mbps,
            state = sample.state,
        )
    end

    second_ground_series = GSLPhysicalLinkSeries(
        2,
        time_grid,
        [
            [
                remap_gsl_sample(
                    sample,
                    ground_id = 2,
                    time_index = time_index,
                    elapsed_s = timeslot_offsets(time_grid)[time_index],
                )
                for sample in samples
            ]
            for (time_index, samples) in pairs(reverse(samples_by_time))
        ],
    )
    access_table = evaluate_access(StarPerfNearestAccessPolicy(), [series, second_ground_series])
    @test ground_count(access_table) == 2
    @test [decision.selected_satellite_id for decision in access_decisions_for_ground(access_table, 1).decisions] ==
        [1, 2, 2]
    @test access_decisions_at(access_table, 1, 2).selected_satellite_id == 2
    @test access_decisions_at(access_table, 2, 1).selected_satellite_id == 2
    @test_throws ArgumentError access_decisions_for_ground(access_table, 3)
    @test_throws ArgumentError evaluate_access(StarPerfNearestAccessPolicy(), GSLPhysicalLinkSeries[])
    @test_throws ArgumentError evaluate_access(StarPerfNearestAccessPolicy(), [series, series])
    other_time_grid = SimulationTimeGrid(SimulationEpoch(DateTime(2026, 1, 1), TimeUTC), 30, 10)
    other_samples = vcat(
        [
            [
                remap_gsl_sample(
                    sample,
                    ground_id = 3,
                    time_index = time_index,
                    elapsed_s = timeslot_offsets(other_time_grid)[time_index],
                )
                for sample in samples
            ]
            for (time_index, samples) in pairs(samples_by_time)
        ],
        [[
            remap_gsl_sample(
                samples_by_time[end][1],
                ground_id = 3,
                time_index = 4,
                elapsed_s = timeslot_offsets(other_time_grid)[4],
            ),
        ]],
    )
    other_time_grid_series = GSLPhysicalLinkSeries(3, other_time_grid, other_samples)
    @test_throws ArgumentError evaluate_access(
        StarPerfNearestAccessPolicy(),
        [series, other_time_grid_series],
    )

    @test_throws ArgumentError AccessState(ground_id = 0)
    @test_throws ArgumentError HysteresisAccessPolicy(NearestAccessPolicy(), margin = -1)
    @test_throws ArgumentError HysteresisAccessPolicy(NearestAccessPolicy(), time_to_trigger_s = -1)
end

@testset "gsl orbital events" begin
    time_grid = SimulationTimeGrid(SimulationEpoch(DateTime(2026, 1, 1), TimeUTC), 3, 1)

    function event_sample(;
        time_index::Int,
        satellite_id::Int = 1,
        distance_km::Real,
        elevation_deg::Real,
        capacity_mbps::Real,
        available::Bool,
    )
        return GSLPhysicalLinkSample(
            ground_id = 1,
            satellite_id = satellite_id,
            time_index = time_index,
            elapsed_s = timeslot_offsets(time_grid)[time_index],
            distance_km = distance_km,
            propagation_delay_s = propagation_delay_s(distance_km),
            elevation_deg = elevation_deg,
            capacity_mbps = capacity_mbps,
            state = available ? LinkAvailable() : LinkUnavailable(),
        )
    end

    series = GSLPhysicalLinkSeries(
        1,
        time_grid,
        [
            [event_sample(time_index = 1, distance_km = 600, elevation_deg = 70, capacity_mbps = 800, available = true)],
            [event_sample(time_index = 2, distance_km = 650, elevation_deg = 65, capacity_mbps = 700, available = true)],
            [event_sample(time_index = 3, distance_km = 700, elevation_deg = -5, capacity_mbps = 0, available = false)],
            [event_sample(time_index = 4, distance_km = 620, elevation_deg = 68, capacity_mbps = 750, available = true)],
        ],
    )

    events = generate_gsl_orbital_events(series)
    @test [event.event_type for event in events] == [:link_up, :link_down, :link_up]
    @test [event.elapsed_s for event in events] == [0, 2, 3]
    @test all(event.link_type == :gsl for event in events)
    @test events[1].endpoint_a == OrbitalLinkEndpoint(:ground, 1)
    @test events[1].endpoint_b == OrbitalLinkEndpoint(:satellite, 1)
    @test events[2].attributes["available"] == false
    @test events[3].capacity_mbps == 750

    oef = generate_gsl_oef(series; metadata = Dict{String,Any}("scenario" => "unit-test"))
    oef_dict = orbital_events_dict(oef)
    @test oef_dict["metadata"]["format"] == "SatelliteSimJulia-OEF"
    @test oef_dict["metadata"]["version"] == "0.1"
    @test oef_dict["metadata"]["step_s"] == 1
    @test oef_dict["metadata"]["link_scope"] == "gsl"
    @test oef_dict["metadata"]["scenario"] == "unit-test"
    @test length(oef_dict["events"]) == 3
    @test oef_dict["events"][1]["event_type"] == "link_up"
    @test oef_dict["events"][2]["event_type"] == "link_down"
    @test oef_dict["events"][3]["event_type"] == "link_up"

    output_path = tempname() * ".json"
    write_orbital_events_json(output_path, oef)
    @test isfile(output_path)
    @test occursin("\"SatelliteSimJulia-OEF\"", read(output_path, String))

    read_oef = read_orbital_events_json(output_path)
    @test read_oef.format == oef.format
    @test read_oef.version == oef.version
    @test read_oef.time_grid.duration_s == oef.time_grid.duration_s
    @test read_oef.time_grid.step_s == oef.time_grid.step_s
    @test length(read_oef.events) == 3
    @test read_oef.events[1].event_type == :link_up
    @test read_oef.events[2].event_type == :link_down
    @test read_oef.events[3].attributes["available"] == true
end

@testset "testbed model objects" begin
    scenario = TestbedScenario(
        id = "minimal_gsl",
        name = "Minimal GSL Testbed",
        description = "unit test",
        time_mode = :simulated,
        oef_path = "outputs/oef/starlink_gsl_oef_demo.json",
    )
    channel_manager = ChannelManagerSpec(
        id = "cm-1",
        mode = :dry_run,
        input_oef = "outputs/oef/starlink_gsl_oef_demo.json",
        execution_target = :host,
        route_scope = :bidirectional,
    )
    environment = TestbedEnvironment(
        backend = :dry_run,
        name_prefix = "ssj",
        work_dir = "outputs/testbeds/minimal_gsl",
        cleanup_policy = :manual,
    )
    networks = [
        TestbedNetwork(id = "experiment", kind = :data, subnet = "10.10.0.0/24", gateway = "", backend = :inherit),
        TestbedNetwork(id = "control", kind = :control, subnet = "", gateway = "", backend = :inherit),
    ]
    nodes = [
        TestbedNode(
            id = "ground-1",
            kind = :ground,
            role = :blue_ground,
            endpoint_kind = :ground,
            endpoint_id = 1,
            ip = "10.10.0.2",
            cpu_cores = 1,
            memory_mb = 512,
            backend = :inherit,
            primary_network = "experiment",
            primary_interface = "eth0",
        ),
        TestbedNode(
            id = "satellite-1",
            kind = :satellite,
            role = :rei_candidate,
            endpoint_kind = :satellite,
            endpoint_id = 1,
            ip = "10.10.0.3",
            image = "rei-v0",
            cpu_cores = 1,
            memory_mb = 512,
            backend = :inherit,
            primary_network = "experiment",
            primary_interface = "eth0",
        ),
    ]
    links = [
        TestbedLink(
            id = "gsl-1",
            kind = :gsl,
            endpoint_a = "ground-1",
            endpoint_b = "satellite-1",
            oef_link_type = :gsl,
            network = "experiment",
            bandwidth_mbps = 1000,
            latency_source = :oef,
            loss_source = :none,
        ),
    ]
    services = [
        TestbedService(
            id = "mission-web",
            node = "satellite-1",
            kind = :http,
            command = "",
            port = 8000,
            enabled = false,
        ),
    ]
    checks = [
        TestbedCheck(
            id = "ground-to-satellite-ping",
            from = "ground-1",
            to = "satellite-1",
            kind = :ping,
            target = "10.10.0.3",
            enabled = false,
        ),
    ]
    spec = TestbedSpec(
        scenario = scenario,
        channel_manager = channel_manager,
        environment = environment,
        networks = networks,
        nodes = nodes,
        links = links,
        services = services,
        checks = checks,
    )

    @test spec.scenario.id == "minimal_gsl"
    @test spec.channel_manager.mode == :dry_run
    @test spec.environment.backend == :dry_run
    @test length(spec.networks) == 2
    @test length(spec.nodes) == 2
    @test spec.nodes[2].image == "rei-v0"
    @test spec.links[1].latency_source == :oef
    @test spec.services[1].port == 8000
    @test spec.checks[1].kind == :ping

    @test_throws ArgumentError TestbedScenario(
        id = "",
        name = "bad",
        time_mode = :simulated,
        oef_path = "x.json",
    )
    @test_throws ArgumentError TestbedEnvironment(
        backend = :bad_backend,
        name_prefix = "ssj",
        work_dir = "outputs/testbeds/bad",
        cleanup_policy = :manual,
    )
    @test_throws ArgumentError TestbedNode(
        id = "bad",
        kind = :unknown,
        role = :blue_ground,
        endpoint_kind = :ground,
        endpoint_id = 1,
        ip = "10.10.0.2",
        primary_network = "experiment",
        primary_interface = "eth0",
    )
    @test_throws ArgumentError TestbedNode(
        id = "bad",
        kind = :ground,
        role = :blue_ground,
        endpoint_kind = :ground,
        endpoint_id = 0,
        ip = "10.10.0.2",
        primary_network = "experiment",
        primary_interface = "eth0",
    )
    @test_throws ArgumentError TestbedService(
        id = "bad-service",
        node = "satellite-1",
        kind = :http,
        port = 70000,
        enabled = false,
    )
    @test_throws ArgumentError TestbedSpec(
        scenario = scenario,
        channel_manager = channel_manager,
        environment = environment,
        networks = TestbedNetwork[],
        nodes = nodes,
        links = links,
    )
end

@testset "testbed config loader" begin
    config_path = joinpath(@__DIR__, "..", "config", "testbeds", "minimal_gsl.toml")
    spec = load_testbed_spec(config_path)

    @test spec.scenario.id == "minimal_gsl"
    @test spec.channel_manager.id == "cm-1"
    @test spec.channel_manager.mode == :vm
    @test spec.environment.backend == :vm
    @test length(spec.networks) == 2
    @test length(spec.nodes) == 2
    @test length(spec.links) == 1
    @test length(spec.services) == 1
    @test length(spec.checks) == 2
    @test spec.nodes[1].id == "ground-1"
    @test spec.nodes[1].endpoint_kind == :ground
    @test spec.nodes[1].image == "ground-ubuntu-24.04"
    @test spec.nodes[2].id == "satellite-1"
    @test spec.nodes[2].endpoint_kind == :satellite
    @test spec.nodes[2].image == "rei-ubuntu-20.04"
    @test spec.links[1].endpoint_a == "ground-1"
    @test spec.links[1].endpoint_b == "satellite-1"
    @test spec.services[1].enabled == false
    @test spec.checks[1].kind == :ping

    output = sprint(print_testbed_spec, spec)
    @test occursin("TestbedSpec: minimal_gsl", output)
    @test occursin("ground-1", output)
    @test occursin("satellite-1", output)
    @test occursin("ground-to-satellite-http", output)

    missing_field_path = tempname() * ".toml"
    write(
        missing_field_path,
        """
        [scenario]
        id = "bad"
        name = "Bad"
        time_mode = "simulated"

        [channel_manager]
        id = "cm-1"
        mode = "dry_run"
        input_oef = "x.json"
        execution_target = "host"
        route_scope = "bidirectional"

        [environment]
        backend = "dry_run"
        name_prefix = "ssj"
        work_dir = "outputs/testbeds/bad"
        cleanup_policy = "manual"

        [[networks]]
        id = "experiment"
        kind = "data"
        subnet = "10.10.0.0/24"
        gateway = ""
        backend = "inherit"

        [[nodes]]
        id = "ground-1"
        kind = "ground"
        role = "blue_ground"
        endpoint_kind = "ground"
        endpoint_id = 1
        ip = "10.10.0.2"
        backend = "inherit"
        primary_network = "experiment"
        primary_interface = "eth0"

        [[links]]
        id = "gsl-1"
        kind = "gsl"
        endpoint_a = "ground-1"
        endpoint_b = "satellite-1"
        oef_link_type = "gsl"
        network = "experiment"
        bandwidth_mbps = 1000
        latency_source = "oef"
        loss_source = "none"
        """,
    )
    @test_throws ArgumentError load_testbed_spec(missing_field_path)
end

@testset "image catalog" begin
    config_path = joinpath(@__DIR__, "..", "config", "testbeds", "minimal_gsl.toml")
    catalog_path = joinpath(@__DIR__, "..", "config", "image_catalogs", "minimal.toml")
    spec = load_testbed_spec(config_path)
    catalog = load_image_catalog(catalog_path)

    @test catalog.id == "minimal"
    @test length(catalog.images) == 5
    @test find_image(catalog, "rei-ubuntu-20.04").kind == :rei
    @test find_image(catalog, "rei-ubuntu-20.04").provision_script == "scripts/materialization/provision/rei_minimal.sh"
    @test find_image(catalog, "ground-ubuntu-24.04").backend == :vm
    @test effective_vm_image(spec.nodes[1], catalog) == "template:ubuntu-lts"
    @test effective_ssh_user(spec.nodes[2], catalog) == "lima"
    @test effective_memory_mb(spec.nodes[2], catalog) == 512
    @test validate_testbed_images(spec, catalog) === nothing

    bad_node = TestbedNode(
        id = "ground-1",
        kind = :ground,
        role = :blue_ground,
        endpoint_kind = :ground,
        endpoint_id = 1,
        ip = "10.10.0.2",
        image = "missing-image",
        cpu_cores = 1,
        memory_mb = 512,
        backend = :inherit,
        primary_network = "experiment",
        primary_interface = "eth0",
    )
    bad_spec = TestbedSpec(
        scenario = spec.scenario,
        channel_manager = spec.channel_manager,
        environment = spec.environment,
        networks = spec.networks,
        nodes = [bad_node, spec.nodes[2]],
        links = spec.links,
        services = spec.services,
        checks = spec.checks,
    )
    @test_throws ArgumentError validate_testbed_images(bad_spec, catalog)

    duplicate_catalog_path = tempname() * ".toml"
    write(
        duplicate_catalog_path,
        """
        [catalog]
        id = "bad"
        name = "Bad"

        [[images]]
        id = "dup"
        name = "Duplicate A"
        kind = "ground"
        backend = "vm"
        base = "template:ubuntu-lts"

        [[images]]
        id = "dup"
        name = "Duplicate B"
        kind = "ground"
        backend = "vm"
        base = "template:ubuntu-lts"
        """,
    )
    @test_throws ArgumentError load_image_catalog(duplicate_catalog_path)

    output = sprint(print_image_catalog, catalog)
    @test occursin("ImageCatalog: minimal", output)
    @test occursin("rei-ubuntu-20.04", output)
end

@testset "testbed realization" begin
    config_path = joinpath(@__DIR__, "..", "config", "testbeds", "minimal_gsl.toml")
    spec = load_testbed_spec(config_path)
    plan = realize_testbed_spec(spec)

    @test plan.scenario_id == "minimal_gsl"
    @test plan.backend == :vm
    @test plan.work_dir == "outputs/testbeds/minimal_gsl"
    @test length(plan.networks) == 2
    @test length(plan.nodes) == 2
    @test length(plan.endpoint_mappings) == 2
    @test plan.networks[1].runtime_name == "ssj-experiment"
    @test plan.nodes[1].runtime_name == "ssj-ground-1"
    @test plan.nodes[1].backend == :vm
    @test plan.endpoint_mappings[1].endpoint_kind == :ground
    @test plan.endpoint_mappings[1].node_id == "ground-1"

    output = sprint(print_testbed_realization_plan, plan)
    @test occursin("TestbedRealizationPlan: minimal_gsl", output)
    @test occursin("ssj-ground-1", output)
    @test occursin("ground:1 -> ground-1", output)

    duplicate_ip_nodes = copy(spec.nodes)
    duplicate_ip_nodes[2] = TestbedNode(
        id = "satellite-1",
        kind = :satellite,
        role = :rei_candidate,
        endpoint_kind = :satellite,
        endpoint_id = 1,
        ip = "10.10.0.2",
        cpu_cores = 1,
        memory_mb = 512,
        backend = :inherit,
        primary_network = "experiment",
        primary_interface = "eth0",
    )
    duplicate_ip_spec = TestbedSpec(
        scenario = spec.scenario,
        channel_manager = spec.channel_manager,
        environment = spec.environment,
        networks = spec.networks,
        nodes = duplicate_ip_nodes,
        links = spec.links,
        services = spec.services,
        checks = spec.checks,
    )
    @test_throws ArgumentError validate_testbed_spec(duplicate_ip_spec)

    bad_link_spec = TestbedSpec(
        scenario = spec.scenario,
        channel_manager = spec.channel_manager,
        environment = spec.environment,
        networks = spec.networks,
        nodes = spec.nodes,
        links = [
            TestbedLink(
                id = "bad-link",
                kind = :gsl,
                endpoint_a = "ground-1",
                endpoint_b = "missing-satellite",
                oef_link_type = :gsl,
                network = "experiment",
                bandwidth_mbps = 1000,
                latency_source = :oef,
                loss_source = :none,
            ),
        ],
        services = spec.services,
        checks = spec.checks,
    )
    @test_throws ArgumentError validate_testbed_spec(bad_link_spec)

    bad_network_node = TestbedNode(
        id = "ground-1",
        kind = :ground,
        role = :blue_ground,
        endpoint_kind = :ground,
        endpoint_id = 1,
        ip = "10.10.0.2",
        cpu_cores = 1,
        memory_mb = 512,
        backend = :inherit,
        primary_network = "missing-network",
        primary_interface = "eth0",
    )
    bad_network_spec = TestbedSpec(
        scenario = spec.scenario,
        channel_manager = spec.channel_manager,
        environment = spec.environment,
        networks = spec.networks,
        nodes = [bad_network_node, spec.nodes[2]],
        links = spec.links,
        services = spec.services,
        checks = spec.checks,
    )
    @test_throws ArgumentError validate_testbed_spec(bad_network_spec)

    bad_service_spec = TestbedSpec(
        scenario = spec.scenario,
        channel_manager = spec.channel_manager,
        environment = spec.environment,
        networks = spec.networks,
        nodes = spec.nodes,
        links = spec.links,
        services = [
            TestbedService(
                id = "bad-service",
                node = "missing-node",
                kind = :http,
                port = 8000,
                enabled = false,
            ),
        ],
        checks = spec.checks,
    )
    @test_throws ArgumentError validate_testbed_spec(bad_service_spec)
end

@testset "testbed VM materialization" begin
    config_path = joinpath(@__DIR__, "..", "config", "testbeds", "minimal_gsl.toml")
    spec = load_testbed_spec(config_path)
    plan = realize_testbed_spec(spec)
    catalog = load_image_catalog(joinpath(@__DIR__, "..", "config", "image_catalogs", "minimal.toml"))
    materialization = write_lima_vm_files(spec, plan; network = "lima:user-v2", image_catalog = catalog)

    @test materialization.scenario_id == "minimal_gsl"
    @test materialization.backend == :vm
    @test materialization.network == "lima:user-v2"
    @test length(materialization.nodes) == 2
    @test materialization.nodes[1].runtime_name == "ssj-ground-1"
    @test materialization.nodes[1].lima_hostname == "lima-ssj-ground-1.internal"
    @test materialization.nodes[2].runtime_name == "ssj-satellite-1"

    ground_yaml = read(materialization.nodes[1].config_path, String)
    @test occursin("template:ubuntu-lts", ground_yaml)
    @test occursin("SSJ_NODE_ID=ground-1", ground_yaml)
    @test occursin("SSJ_OEF_ENDPOINT=ground:1", ground_yaml)
    @test occursin("SSJ_CONFIGURED_IP=10.10.0.2", ground_yaml)
    @test occursin("SSJ_IMAGE_ID=ground-ubuntu-24.04", ground_yaml)
    @test occursin("SSJ_SSH_USER=lima", ground_yaml)

    satellite_yaml = read(materialization.nodes[2].config_path, String)
    @test occursin("SSJ_NODE_ID=satellite-1", satellite_yaml)
    @test occursin("SSJ_IMAGE_ID=rei-ubuntu-20.04", satellite_yaml)
    @test occursin("SatelliteSimJulia Minimal REI Agent", satellite_yaml)
    @test occursin("SSJ_REI_OEF_PATH=/opt/ssj/rei/oef.json", satellite_yaml)
    @test occursin("def load_oef()", satellite_yaml)
    @test occursin("\"current_links\"", satellite_yaml)
    @test occursin("\"next_event\"", satellite_yaml)
    @test occursin("ssj-rei-agent.service", satellite_yaml)
    @test occursin("synthetic_malware.py", satellite_yaml)

    start_script = read(materialization.start_script_path, String)
    @test occursin("--network 'lima:user-v2'", start_script)
    @test occursin("ssj-ground-1.yaml", start_script)
    @test occursin("ssj-satellite-1.yaml", start_script)

    @test materialization.runtime_registry_path == joinpath(materialization.work_dir, "runtime_endpoints.json")
    @test isfile(materialization.runtime_registry_path)
    registry = read_runtime_endpoint_registry(materialization.runtime_registry_path)
    @test registry.scenario_id == "minimal_gsl"
    @test registry.network == "lima:user-v2"
    @test length(registry.endpoints) == 2
    satellite_endpoint = find_runtime_endpoint(registry, OrbitalLinkEndpoint(:satellite, 1))
    @test runtime_endpoint_label(satellite_endpoint) == "satellite:1"
    @test satellite_endpoint.node_id == "satellite-1"
    @test satellite_endpoint.configured_ip == "10.10.0.3"
    @test satellite_endpoint.runtime_hostname == "lima-ssj-satellite-1.internal"
    @test satellite_endpoint.runtime_ip == ""
    @test length(satellite_endpoint.services) == 1
    @test satellite_endpoint.services[1].url == "http://lima-ssj-satellite-1.internal:8000/mission_payload.json"

    refreshed_registry, refresh_results = refresh_runtime_endpoint_registry(
        registry;
        resolver = endpoint -> endpoint.endpoint_kind == :satellite ? "192.168.104.23\n" : "",
    )
    @test length(refresh_results) == 2
    refreshed_satellite = find_runtime_endpoint(refreshed_registry, OrbitalLinkEndpoint(:satellite, 1))
    refreshed_ground = find_runtime_endpoint(refreshed_registry, OrbitalLinkEndpoint(:ground, 1))
    @test refreshed_satellite.runtime_ip == "192.168.104.23"
    @test refreshed_ground.runtime_ip == ""
    @test refresh_results[2].resolved
    @test runtime_endpoint_refresh_result_dict(refresh_results[2])["runtime_ip"] == "192.168.104.23"

    failed_refresh_registry, failed_refresh_results = refresh_runtime_endpoint_registry(
        refreshed_registry;
        resolver = endpoint -> error("not running"),
    )
    failed_refresh_satellite = find_runtime_endpoint(failed_refresh_registry, OrbitalLinkEndpoint(:satellite, 1))
    @test failed_refresh_satellite.runtime_ip == "192.168.104.23"
    @test !failed_refresh_results[1].resolved
    @test occursin("not running", failed_refresh_results[1].error_message)

    refresh_path = joinpath(materialization.work_dir, "runtime_endpoints_refresh_test.json")
    write_runtime_endpoint_registry(refresh_path, registry)
    file_refreshed_registry, _ = refresh_runtime_endpoint_registry_file(
        refresh_path;
        resolver = endpoint -> endpoint.endpoint_kind == :ground ? "192.168.104.22" : "",
    )
    @test find_runtime_endpoint(file_refreshed_registry, OrbitalLinkEndpoint(:ground, 1)).runtime_ip == "192.168.104.22"
    reread_refreshed_registry = read_runtime_endpoint_registry(refresh_path)
    @test find_runtime_endpoint(reread_refreshed_registry, OrbitalLinkEndpoint(:ground, 1)).runtime_ip == "192.168.104.22"

    output = sprint(print_testbed_materialization_plan, materialization)
    @test occursin("TestbedMaterializationPlan: minimal_gsl", output)
    @test occursin("lima-ssj-satellite-1.internal", output)
    @test occursin("runtime_endpoints.json", output)
end

@testset "orbital link windows" begin
    time_grid = SimulationTimeGrid(SimulationEpoch(DateTime(2026, 1, 1), TimeUTC), 4, 1)

    function test_orbital_event(event_type::Symbol, time_index::Int; satellite_id::Int = 1)
        distance_km = event_type == :link_down ? 2000.0 : 500.0
        return OrbitalLinkEvent(
            event_type = event_type,
            link_type = :gsl,
            time_index = time_index,
            elapsed_s = timeslot_offsets(time_grid)[time_index],
            endpoint_a = OrbitalLinkEndpoint(:ground, 1),
            endpoint_b = OrbitalLinkEndpoint(:satellite, satellite_id),
            distance_km = distance_km,
            propagation_delay_s = propagation_delay_s(distance_km),
            capacity_mbps = event_type == :link_down ? 0 : 1000,
        )
    end

    closed_oef = OrbitalEventsFile(
        time_grid,
        [
            test_orbital_event(:link_up, 1),
            test_orbital_event(:link_down, 4),
        ],
    )
    closed_windows = summarize_link_windows(closed_oef)
    @test length(closed_windows) == 1
    @test closed_windows[1].endpoint_a == OrbitalLinkEndpoint(:ground, 1)
    @test closed_windows[1].endpoint_b == OrbitalLinkEndpoint(:satellite, 1)
    @test closed_windows[1].link_up_elapsed_s == 0
    @test closed_windows[1].link_down_elapsed_s == 3
    @test link_window_duration_s(closed_windows[1]) == 3

    closed_window_dict = window_dict(closed_windows[1])
    @test closed_window_dict["link_type"] == "gsl"
    @test closed_window_dict["link_up_time_s"] == 0
    @test closed_window_dict["link_down_time_s"] == 3
    @test closed_window_dict["duration_s"] == 3

    open_oef = OrbitalEventsFile(time_grid, [test_orbital_event(:link_up, 2; satellite_id = 2)])
    open_windows = summarize_link_windows(open_oef)
    @test length(open_windows) == 1
    @test open_windows[1].endpoint_b == OrbitalLinkEndpoint(:satellite, 2)
    @test open_windows[1].link_up_elapsed_s == 1
    @test open_windows[1].link_down_elapsed_s === nothing
    @test link_window_duration_s(open_windows[1]) === nothing

    duplicate_up_oef = OrbitalEventsFile(
        time_grid,
        [
            test_orbital_event(:link_up, 1),
            test_orbital_event(:link_up, 2),
        ],
    )
    @test_throws ArgumentError summarize_link_windows(duplicate_up_oef)

    down_without_up_oef = OrbitalEventsFile(time_grid, [test_orbital_event(:link_down, 2)])
    @test_throws ArgumentError summarize_link_windows(down_without_up_oef)
end

@testset "dry-run channel manager" begin
    time_grid = SimulationTimeGrid(SimulationEpoch(DateTime(2026, 1, 1), TimeUTC), 2, 1)

    up = OrbitalLinkEvent(
        event_type = :link_up,
        link_type = :gsl,
        time_index = 1,
        elapsed_s = 0,
        endpoint_a = OrbitalLinkEndpoint(:ground, 1),
        endpoint_b = OrbitalLinkEndpoint(:satellite, 2),
        distance_km = 500,
        propagation_delay_s = propagation_delay_s(500),
        capacity_mbps = 1000,
    )
    down = OrbitalLinkEvent(
        event_type = :link_down,
        link_type = :gsl,
        time_index = 3,
        elapsed_s = 2,
        endpoint_a = OrbitalLinkEndpoint(:ground, 1),
        endpoint_b = OrbitalLinkEndpoint(:satellite, 2),
        distance_km = 2000,
        propagation_delay_s = propagation_delay_s(2000),
        capacity_mbps = 0,
    )
    oef = OrbitalEventsFile(time_grid, [up, down])

    manager = DryRunChannelManager()
    actions = execute_oef!(manager, oef)
    @test length(actions) == 2
    @test actions === manager.actions
    @test [action.action_type for action in actions] == [:restore_route, :blackhole_route]
    @test occursin("restore route", actions[1].description)
    @test occursin("blackhole route", actions[2].description)

    first_action = action_dict(actions[1])
    @test first_action["action_type"] == "restore_route"
    @test first_action["endpoint_a"]["kind"] == "ground"
    @test first_action["endpoint_b"]["id"] == 2

    update = OrbitalLinkEvent(
        event_type = :link_update,
        link_type = :gsl,
        time_index = 2,
        elapsed_s = 1,
        endpoint_a = OrbitalLinkEndpoint(:ground, 1),
        endpoint_b = OrbitalLinkEndpoint(:satellite, 2),
        distance_km = 600,
        propagation_delay_s = propagation_delay_s(600),
        capacity_mbps = 900,
    )
    @test_throws ArgumentError channel_manager_action(update)
end

@testset "vm route channel manager commands" begin
    config_path = joinpath(@__DIR__, "..", "config", "testbeds", "minimal_gsl.toml")
    spec = load_testbed_spec(config_path)
    realization = realize_testbed_spec(spec)
    materialization = write_lima_vm_files(spec, realization; network = "lima:user-v2")

    time_grid = SimulationTimeGrid(SimulationEpoch(DateTime(2026, 1, 1), TimeUTC), 2, 1)
    up = OrbitalLinkEvent(
        event_type = :link_up,
        link_type = :gsl,
        time_index = 1,
        elapsed_s = 0,
        endpoint_a = OrbitalLinkEndpoint(:ground, 1),
        endpoint_b = OrbitalLinkEndpoint(:satellite, 1),
        distance_km = 500,
        propagation_delay_s = propagation_delay_s(500),
        capacity_mbps = 1000,
    )
    down = OrbitalLinkEvent(
        event_type = :link_down,
        link_type = :gsl,
        time_index = 3,
        elapsed_s = 2,
        endpoint_a = OrbitalLinkEndpoint(:ground, 1),
        endpoint_b = OrbitalLinkEndpoint(:satellite, 1),
        distance_km = 2000,
        propagation_delay_s = propagation_delay_s(2000),
        capacity_mbps = 0,
    )
    oef = OrbitalEventsFile(time_grid, [up, down])
    manager = VMRouteChannelManager(materialization; execute = false)
    actions = execute_oef!(manager, oef)

    @test manager.runtime_registry !== nothing
    @test length(actions) == 2
    @test length(manager.commands) == 4
    @test manager.commands[1].action_type == :restore_route
    @test manager.commands[1].source_runtime_name == "ssj-ground-1"
    @test manager.commands[1].destination_hostname == "lima-ssj-satellite-1.internal"
    @test occursin("ip route del blackhole", manager.commands[1].command)
    @test manager.commands[3].action_type == :blackhole_route
    @test occursin("ip route replace blackhole", manager.commands[3].command)

    command_data = route_command_dict(manager.commands[3])
    @test command_data["source_node"] == "ground-1"
    @test command_data["action_type"] == "blackhole_route"
end

@testset "channel manager OEF replay scheduler" begin
    time_grid = SimulationTimeGrid(SimulationEpoch(DateTime(2026, 1, 1), TimeUTC), 4, 2)
    down = OrbitalLinkEvent(
        event_type = :link_down,
        link_type = :gsl,
        time_index = 3,
        elapsed_s = 4,
        endpoint_a = OrbitalLinkEndpoint(:ground, 1),
        endpoint_b = OrbitalLinkEndpoint(:satellite, 1),
        distance_km = 2000,
        propagation_delay_s = propagation_delay_s(2000),
        capacity_mbps = 0,
    )
    up = OrbitalLinkEvent(
        event_type = :link_up,
        link_type = :gsl,
        time_index = 1,
        elapsed_s = 0,
        endpoint_a = OrbitalLinkEndpoint(:ground, 1),
        endpoint_b = OrbitalLinkEndpoint(:satellite, 1),
        distance_km = 500,
        propagation_delay_s = propagation_delay_s(500),
        capacity_mbps = 1000,
    )
    update = OrbitalLinkEvent(
        event_type = :link_update,
        link_type = :gsl,
        time_index = 2,
        elapsed_s = 2,
        endpoint_a = OrbitalLinkEndpoint(:ground, 1),
        endpoint_b = OrbitalLinkEndpoint(:satellite, 1),
        distance_km = 600,
        propagation_delay_s = propagation_delay_s(600),
        capacity_mbps = 800,
    )
    oef = OrbitalEventsFile(time_grid, [down, update, up])
    sorted_events = sorted_channel_manager_events(oef)
    @test [event.event_type for event in sorted_events] == [:link_up, :link_down]

    slept = Float64[]
    manager = DryRunChannelManager()
    records = replay_oef!(manager, oef; speedup = 2.0, sleep_fn = seconds -> push!(slept, seconds))
    @test [record.scheduled_time_s for record in records] == [0, 4]
    @test [record.waited_s for record in records] == [0.0, 2.0]
    @test slept == [2.0]
    @test [record.action.action_type for record in records] == [:restore_route, :blackhole_route]

    record_data = schedule_record_dict(records[2])
    @test record_data["scheduled_time_s"] == 4
    @test record_data["action"]["action_type"] == "blackhole_route"

    @test_throws ArgumentError replay_oef!(DryRunChannelManager(), oef; speedup = 0)
end

@testset "dry-run channel manager demo printer" begin
    include(joinpath(@__DIR__, "..", "scripts", "channel_manager", "run_dry_channel_manager_demo.jl"))
    time_grid = SimulationTimeGrid(SimulationEpoch(DateTime(2026, 1, 1), TimeUTC), 1, 1)
    event = OrbitalLinkEvent(
        event_type = :link_up,
        link_type = :gsl,
        time_index = 1,
        elapsed_s = 0,
        endpoint_a = OrbitalLinkEndpoint(:ground, 1),
        endpoint_b = OrbitalLinkEndpoint(:satellite, 1),
        distance_km = 500,
        propagation_delay_s = propagation_delay_s(500),
        capacity_mbps = 1000,
    )
    action = channel_manager_action(event)

    io = IOBuffer()
    print_channel_manager_actions(io, [action])
    output = String(take!(io))
    @test occursin("Channel Manager actions", output)
    @test occursin("restore_route", output)
    @test occursin("ground:1 -> satellite:1", output)
end

@testset "shortest delay routing" begin
    metadata = SourceMetadata("routing-fixture")
    elements = DesignOrbitElementSet(altitude_km = 550, inclination_deg = 53, metadata = metadata)
    satellites_fixture = [
        Satellite(
            identifier = SatelliteId(
                global_id = satellite_id,
                shell_id = 1,
                shell_local_id = satellite_id,
                orbit_plane_id = 1,
                plane_local_slot = satellite_id,
            ),
            orbit_elements = elements,
        )
        for satellite_id in 1:3
    ]
    links = [
        SatelliteLink(
            id = 1,
            endpoint_a = LinkEndpoint(satellites_fixture[1]),
            endpoint_b = LinkEndpoint(satellites_fixture[2]),
        ),
        SatelliteLink(
            id = 2,
            endpoint_a = LinkEndpoint(satellites_fixture[2]),
            endpoint_b = LinkEndpoint(satellites_fixture[3]),
        ),
        SatelliteLink(
            id = 3,
            endpoint_a = LinkEndpoint(satellites_fixture[1]),
            endpoint_b = LinkEndpoint(satellites_fixture[3]),
        ),
    ]
    topology = ConstellationTopology("RoutingFixture", links)
    time_grid = SimulationTimeGrid(SimulationEpoch(DateTime(2026, 1, 1), TimeUTC), 10, 10)

    function isl_sample(;
        link_id,
        time_index,
        endpoint_a_id,
        endpoint_b_id,
        delay_s,
        available = true,
    )
        return ISLPhysicalLinkSample(
            link_id = link_id,
            time_index = time_index,
            elapsed_s = timeslot_offsets(time_grid)[time_index],
            endpoint_a_id = endpoint_a_id,
            endpoint_b_id = endpoint_b_id,
            distance_km = delay_s * SPEED_OF_LIGHT_KM_S,
            propagation_delay_s = delay_s,
            capacity_mbps = available ? 1000 : 0,
            state = available ? LinkAvailable() : LinkUnavailable(),
            line_of_sight = available,
        )
    end

    isl_series = ISLPhysicalLinkSeries(
        topology,
        time_grid,
        [
            [
                isl_sample(link_id = 1, time_index = 1, endpoint_a_id = 1, endpoint_b_id = 2, delay_s = 1),
                isl_sample(link_id = 2, time_index = 1, endpoint_a_id = 2, endpoint_b_id = 3, delay_s = 1),
                isl_sample(link_id = 3, time_index = 1, endpoint_a_id = 1, endpoint_b_id = 3, delay_s = 5),
            ],
            [
                isl_sample(link_id = 1, time_index = 2, endpoint_a_id = 1, endpoint_b_id = 2, delay_s = 1),
                isl_sample(
                    link_id = 2,
                    time_index = 2,
                    endpoint_a_id = 2,
                    endpoint_b_id = 3,
                    delay_s = 1,
                    available = false,
                ),
                isl_sample(
                    link_id = 3,
                    time_index = 2,
                    endpoint_a_id = 1,
                    endpoint_b_id = 3,
                    delay_s = 5,
                    available = false,
                ),
            ],
        ],
    )

    function access_sample(ground_id, satellite_id, time_index, delay_s)
        return GSLPhysicalLinkSample(
            ground_id = ground_id,
            satellite_id = satellite_id,
            time_index = time_index,
            elapsed_s = timeslot_offsets(time_grid)[time_index],
            distance_km = delay_s * SPEED_OF_LIGHT_KM_S,
            propagation_delay_s = delay_s,
            elevation_deg = 80,
            capacity_mbps = 1000,
            state = LinkAvailable(),
        )
    end

    function access_decision(ground_id, satellite_id, time_index, delay_s; reason = :initial_access)
        sample = access_sample(ground_id, satellite_id, time_index, delay_s)
        return AccessDecision(
            ground_id = ground_id,
            time_index = time_index,
            elapsed_s = timeslot_offsets(time_grid)[time_index],
            selected_satellite_id = satellite_id,
            switched = reason != :stay,
            reason = reason,
            selected_sample = sample,
        )
    end

    source_series = AccessDecisionSeries(
        1,
        time_grid,
        [
            access_decision(1, 1, 1, 0.1),
            access_decision(1, 1, 2, 0.1, reason = :stay),
        ],
    )
    destination_series = AccessDecisionSeries(
        2,
        time_grid,
        [
            access_decision(2, 3, 1, 0.2),
            access_decision(2, 3, 2, 0.2, reason = :stay),
        ],
    )
    access_table = AccessDecisionTable(time_grid, [source_series, destination_series])

    request = RouteRequest(1, 2)
    route = route_path_at(request, isl_series, access_table, 1)
    @test route.reachable
    @test route.reason == :shortest_delay
    @test route.source_access_satellite_id == 1
    @test route.destination_access_satellite_id == 3
    @test route.satellite_path == [1, 2, 3]
    @test route.isl_link_ids == [1, 2]
    @test route.isl_delay_s ≈ 2.0
    @test route.total_delay_s ≈ 2.3

    unreachable = route_path_at(request, isl_series, access_table, 2)
    @test !unreachable.reachable
    @test unreachable.reason == :isl_unreachable
    @test unreachable.source_access_satellite_id == 1
    @test unreachable.destination_access_satellite_id == 3

    no_source_access = AccessDecisionSeries(
        1,
        time_grid,
        [
            AccessDecision(
                ground_id = 1,
                time_index = 1,
                elapsed_s = 0,
                selected_satellite_id = nothing,
                reason = :no_available_satellite,
            ),
            access_decision(1, 1, 2, 0.1),
        ],
    )
    no_access_table = AccessDecisionTable(time_grid, [no_source_access, destination_series])
    no_access_route = route_path_at(request, isl_series, no_access_table, 1)
    @test !no_access_route.reachable
    @test no_access_route.reason == :source_no_access

    routes = route_series(request, isl_series, access_table)
    @test route_at(routes, 1).satellite_path == [1, 2, 3]
    @test length(reachable_routes(routes)) == 1
    @test_throws ArgumentError RouteRequest(1, 1)
end

@testset "traffic evaluation" begin
    metadata = SourceMetadata("traffic-fixture")
    elements = DesignOrbitElementSet(altitude_km = 550, inclination_deg = 53, metadata = metadata)
    satellites_fixture = [
        Satellite(
            identifier = SatelliteId(
                global_id = satellite_id,
                shell_id = 1,
                shell_local_id = satellite_id,
                orbit_plane_id = 1,
                plane_local_slot = satellite_id,
            ),
            orbit_elements = elements,
        )
        for satellite_id in 1:3
    ]
    topology = ConstellationTopology(
        "TrafficFixture",
        [
            SatelliteLink(
                id = 1,
                endpoint_a = LinkEndpoint(satellites_fixture[1]),
                endpoint_b = LinkEndpoint(satellites_fixture[2]),
            ),
            SatelliteLink(
                id = 2,
                endpoint_a = LinkEndpoint(satellites_fixture[2]),
                endpoint_b = LinkEndpoint(satellites_fixture[3]),
            ),
        ],
    )
    time_grid = SimulationTimeGrid(SimulationEpoch(DateTime(2026, 1, 1), TimeUTC), 10, 10)

    function traffic_isl_sample(; link_id, time_index, endpoint_a_id, endpoint_b_id, available = true)
        return ISLPhysicalLinkSample(
            link_id = link_id,
            time_index = time_index,
            elapsed_s = timeslot_offsets(time_grid)[time_index],
            endpoint_a_id = endpoint_a_id,
            endpoint_b_id = endpoint_b_id,
            distance_km = 1000,
            propagation_delay_s = 1,
            capacity_mbps = available ? 500 : 0,
            state = available ? LinkAvailable() : LinkUnavailable(),
            line_of_sight = available,
        )
    end

    isl_series = ISLPhysicalLinkSeries(
        topology,
        time_grid,
        [
            [
                traffic_isl_sample(link_id = 1, time_index = 1, endpoint_a_id = 1, endpoint_b_id = 2),
                traffic_isl_sample(link_id = 2, time_index = 1, endpoint_a_id = 2, endpoint_b_id = 3),
            ],
            [
                traffic_isl_sample(link_id = 1, time_index = 2, endpoint_a_id = 1, endpoint_b_id = 2),
                traffic_isl_sample(
                    link_id = 2,
                    time_index = 2,
                    endpoint_a_id = 2,
                    endpoint_b_id = 3,
                    available = false,
                ),
            ],
        ],
    )

    function traffic_gsl_sample(ground_id, satellite_id, time_index)
        return GSLPhysicalLinkSample(
            ground_id = ground_id,
            satellite_id = satellite_id,
            time_index = time_index,
            elapsed_s = timeslot_offsets(time_grid)[time_index],
            distance_km = 300,
            propagation_delay_s = 0.1,
            elevation_deg = 80,
            capacity_mbps = 1000,
            state = LinkAvailable(),
        )
    end

    function traffic_access_decision(ground_id, satellite_id, time_index)
        sample = traffic_gsl_sample(ground_id, satellite_id, time_index)
        return AccessDecision(
            ground_id = ground_id,
            time_index = time_index,
            elapsed_s = timeslot_offsets(time_grid)[time_index],
            selected_satellite_id = satellite_id,
            switched = time_index == 1,
            reason = time_index == 1 ? :initial_access : :stay,
            selected_sample = sample,
        )
    end

    access_table = AccessDecisionTable(
        time_grid,
        [
            AccessDecisionSeries(
                1,
                time_grid,
                [
                    traffic_access_decision(1, 1, 1),
                    traffic_access_decision(1, 1, 2),
                ],
            ),
            AccessDecisionSeries(
                2,
                time_grid,
                [
                    traffic_access_decision(2, 3, 1),
                    traffic_access_decision(2, 3, 2),
                ],
            ),
        ],
    )

    demand = TrafficDemand(
        id = 1,
        source_ground_id = 1,
        destination_ground_id = 2,
        start_elapsed_s = 0,
        end_elapsed_s = 20,
        rate_mbps = 600,
    )
    evaluation = evaluate_traffic([demand], isl_series, access_table)

    assignments_t1 = traffic_assignments_at(evaluation, 1)
    @test length(assignments_t1) == 1
    @test assignments_t1[1].offered_mbps == 600
    @test assignments_t1[1].carried_mbps == 600
    @test assignments_t1[1].dropped_mbps == 0
    @test assignments_t1[1].route.satellite_path == [1, 2, 3]

    loads_t1 = traffic_link_loads_at(evaluation, 1)
    @test length(loads_t1) == 4
    isl_loads_t1 = [load for load in loads_t1 if load.link_type == :isl]
    gsl_loads_t1 = [load for load in loads_t1 if load.link_type == :gsl]
    @test length(isl_loads_t1) == 2
    @test all(load.load_mbps == 600 for load in isl_loads_t1)
    @test all(load.capacity_mbps == 500 for load in isl_loads_t1)
    @test all(load.congested for load in isl_loads_t1)
    @test length(gsl_loads_t1) == 2
    @test all(load.load_mbps == 600 for load in gsl_loads_t1)
    @test all(!load.congested for load in gsl_loads_t1)

    assignments_t2 = traffic_assignments_at(evaluation, 2)
    @test length(assignments_t2) == 1
    @test !assignments_t2[1].route.reachable
    @test assignments_t2[1].route.reason == :isl_unreachable
    @test assignments_t2[1].carried_mbps == 0
    @test assignments_t2[1].dropped_mbps == 600
    @test isempty(traffic_link_loads_at(evaluation, 2))

    @test_throws ArgumentError TrafficDemand(
        id = 1,
        source_ground_id = 1,
        destination_ground_id = 1,
        start_elapsed_s = 0,
        end_elapsed_s = 10,
        rate_mbps = 1,
    )
    @test_throws ArgumentError evaluate_traffic([demand, demand], isl_series, access_table)
end

@testset "satellite communication energy mapping" begin
    request = RouteRequest(1, 2)
    time_grid = SimulationTimeGrid(SimulationEpoch(DateTime(2026, 1, 1), TimeUTC), 10, 10)
    route = RoutePath(
        request = request,
        time_index = 1,
        elapsed_s = 0,
        source_access_satellite_id = 1,
        destination_access_satellite_id = 3,
        satellite_path = [1, 2, 3],
        isl_link_ids = [1, 2],
        isl_delay_s = 2,
        source_gsl_delay_s = 0.1,
        destination_gsl_delay_s = 0.1,
        total_delay_s = 2.2,
        reachable = true,
        reason = :shortest_delay,
    )
    unreachable = RoutePath(
        request = request,
        time_index = 2,
        elapsed_s = 10,
        source_access_satellite_id = 1,
        destination_access_satellite_id = 3,
        reachable = false,
        reason = :isl_unreachable,
    )
    evaluation = TrafficEvaluation(
        time_grid,
        [
            TrafficDemand(
                id = 1,
                source_ground_id = 1,
                destination_ground_id = 2,
                start_elapsed_s = 0,
                end_elapsed_s = 20,
                rate_mbps = 600,
            ),
        ],
        [
            [
                TrafficAssignment(
                    demand_id = 1,
                    time_index = 1,
                    elapsed_s = 0,
                    route = route,
                    offered_mbps = 600,
                    carried_mbps = 600,
                    dropped_mbps = 0,
                ),
            ],
            [
                TrafficAssignment(
                    demand_id = 1,
                    time_index = 2,
                    elapsed_s = 10,
                    route = unreachable,
                    offered_mbps = 600,
                    carried_mbps = 0,
                    dropped_mbps = 600,
                ),
            ],
        ],
        [LinkLoadSample[], LinkLoadSample[]],
    )
    model = CommunicationPowerModel(
        gsl_w_per_mbps = 0.1,
        isl_tx_w_per_mbps = 0.2,
        isl_rx_w_per_mbps = 0.3,
    )
    loads = evaluate_satellite_communication_loads(evaluation, 3, model)
    loads_t1 = satellite_communication_loads_at(loads, 1)

    @test loads_t1[1].gsl_load_mbps == 600
    @test loads_t1[1].isl_tx_load_mbps == 600
    @test loads_t1[1].isl_rx_load_mbps == 0
    @test loads_t1[1].communication_load_w == 180
    @test loads_t1[2].gsl_load_mbps == 0
    @test loads_t1[2].isl_tx_load_mbps == 600
    @test loads_t1[2].isl_rx_load_mbps == 600
    @test loads_t1[2].communication_load_w == 300
    @test loads_t1[3].gsl_load_mbps == 600
    @test loads_t1[3].isl_tx_load_mbps == 0
    @test loads_t1[3].isl_rx_load_mbps == 600
    @test loads_t1[3].communication_load_w == 240
    @test all(sample.communication_load_w == 0 for sample in satellite_communication_loads_at(loads, 2))

    table = SatelliteStateTable(
        3;
        power = PowerState(
            battery_capacity_wh = 1000,
            stored_energy_wh = 500,
            solar_generation_w = 100,
            base_load_w = 20,
            payload_load_w = 10,
        ),
    )
    apply_communication_loads!(table, loads, 1)
    @test table[1].power.communication_load_w == 180
    @test table[1].power.base_load_w == 20
    @test table[1].power.payload_load_w == 10
    @test total_load_w(table[1].power) == 210

    @test_throws ArgumentError CommunicationPowerModel(gsl_w_per_mbps = -1)
    @test_throws BoundsError evaluate_satellite_communication_loads(evaluation, 2, model)
end

@testset "energy drain attack and power simulation" begin
    baseline = [
        TrafficDemand(
            id = 1,
            source_ground_id = 1,
            destination_ground_id = 2,
            start_elapsed_s = 0,
            end_elapsed_s = 30,
            rate_mbps = 100,
        ),
    ]
    config = EnergyDrainAttackConfig(
        id_start = 10,
        source_ground_ids = [1, 2],
        destination_ground_ids = [2],
        start_elapsed_s = 10,
        end_elapsed_s = 30,
        rate_mbps = 250,
        flows_per_pair = 2,
    )
    attack_demands = energy_drain_attack_demands(config)
    combined = inject_energy_drain_attack(baseline, config)

    @test length(attack_demands) == 2
    @test [demand.id for demand in attack_demands] == [10, 11]
    @test all(demand.source_ground_id == 1 for demand in attack_demands)
    @test all(demand.destination_ground_id == 2 for demand in attack_demands)
    @test length(combined) == 3
    @test_throws ArgumentError inject_energy_drain_attack(
        baseline,
        EnergyDrainAttackConfig(
            id_start = 1,
            source_ground_ids = [1],
            destination_ground_ids = [2],
            start_elapsed_s = 0,
            end_elapsed_s = 10,
            rate_mbps = 1,
        ),
    )

    time_grid = SimulationTimeGrid(SimulationEpoch(DateTime(2026, 1, 1), TimeUTC), 20, 10)
    loads = SatelliteCommunicationLoadSeries(
        time_grid,
        1,
        [
            [
                SatelliteCommunicationLoadSample(
                    satellite_id = 1,
                    time_index = 1,
                    elapsed_s = 0,
                    communication_load_w = 0,
                ),
            ],
            [
                SatelliteCommunicationLoadSample(
                    satellite_id = 1,
                    time_index = 2,
                    elapsed_s = 10,
                    communication_load_w = 360,
                ),
            ],
            [
                SatelliteCommunicationLoadSample(
                    satellite_id = 1,
                    time_index = 3,
                    elapsed_s = 20,
                    communication_load_w = 0,
                ),
            ],
        ],
    )
    initial = SatelliteStateTable(
        1;
        power = PowerState(
            battery_capacity_wh = 100,
            stored_energy_wh = 50,
            solar_generation_w = 0,
            base_load_w = 0,
            payload_load_w = 0,
        ),
    )
    power_series = simulate_power_states(initial, loads)

    @test power_states_at(power_series, 1)[1].stored_energy_wh == 50
    @test power_states_at(power_series, 1)[1].communication_load_w == 0
    @test power_states_at(power_series, 2)[1].stored_energy_wh == 50
    @test power_states_at(power_series, 2)[1].communication_load_w == 360
    @test power_states_at(power_series, 3)[1].stored_energy_wh == 49
    @test power_states_at(power_series, 3)[1].communication_load_w == 0

    depleted = evolve_power_state(
        PowerState(
            battery_capacity_wh = 1,
            stored_energy_wh = 0.1,
            base_load_w = 360,
        ),
        10,
    )
    @test depleted.stored_energy_wh == 0
    @test_throws ArgumentError EnergyDrainAttackConfig(
        source_ground_ids = [1],
        destination_ground_ids = [1],
        start_elapsed_s = 0,
        end_elapsed_s = 10,
        rate_mbps = 1,
    )
end

@testset "energy drain attack endpoint selection" begin
    metadata = SourceMetadata("attack-selection-fixture")
    elements = DesignOrbitElementSet(altitude_km = 550, inclination_deg = 53, metadata = metadata)
    satellites_fixture = [
        Satellite(
            identifier = SatelliteId(
                global_id = satellite_id,
                shell_id = 1,
                shell_local_id = satellite_id,
                orbit_plane_id = 1,
                plane_local_slot = satellite_id,
            ),
            orbit_elements = elements,
        )
        for satellite_id in 1:3
    ]
    topology = ConstellationTopology(
        "AttackSelectionFixture",
        [
            SatelliteLink(
                id = 1,
                endpoint_a = LinkEndpoint(satellites_fixture[1]),
                endpoint_b = LinkEndpoint(satellites_fixture[2]),
            ),
            SatelliteLink(
                id = 2,
                endpoint_a = LinkEndpoint(satellites_fixture[2]),
                endpoint_b = LinkEndpoint(satellites_fixture[3]),
            ),
        ],
    )
    time_grid = SimulationTimeGrid(SimulationEpoch(DateTime(2026, 1, 1), TimeUTC), 20, 10)

    function selection_isl_sample(; link_id, time_index, endpoint_a_id, endpoint_b_id)
        return ISLPhysicalLinkSample(
            link_id = link_id,
            time_index = time_index,
            elapsed_s = timeslot_offsets(time_grid)[time_index],
            endpoint_a_id = endpoint_a_id,
            endpoint_b_id = endpoint_b_id,
            distance_km = 1000,
            propagation_delay_s = 1,
            capacity_mbps = 1000,
            state = LinkAvailable(),
            line_of_sight = true,
        )
    end

    isl_series = ISLPhysicalLinkSeries(
        topology,
        time_grid,
        [
            [
                selection_isl_sample(link_id = 1, time_index = time_index, endpoint_a_id = 1, endpoint_b_id = 2),
                selection_isl_sample(link_id = 2, time_index = time_index, endpoint_a_id = 2, endpoint_b_id = 3),
            ]
            for time_index in 1:time_count(time_grid)
        ],
    )

    function selection_access_decision(ground_id, satellite_id, time_index)
        sample = GSLPhysicalLinkSample(
            ground_id = ground_id,
            satellite_id = satellite_id,
            time_index = time_index,
            elapsed_s = timeslot_offsets(time_grid)[time_index],
            distance_km = 300,
            propagation_delay_s = 0.1,
            elevation_deg = 80,
            capacity_mbps = 1000,
            state = LinkAvailable(),
        )
        return AccessDecision(
            ground_id = ground_id,
            time_index = time_index,
            elapsed_s = timeslot_offsets(time_grid)[time_index],
            selected_satellite_id = satellite_id,
            switched = time_index == 1,
            reason = time_index == 1 ? :initial_access : :stay,
            selected_sample = sample,
        )
    end

    access_table = AccessDecisionTable(
        time_grid,
        [
            AccessDecisionSeries(
                1,
                time_grid,
                [selection_access_decision(1, 1, time_index) for time_index in 1:time_count(time_grid)],
            ),
            AccessDecisionSeries(
                2,
                time_grid,
                [selection_access_decision(2, 2, time_index) for time_index in 1:time_count(time_grid)],
            ),
            AccessDecisionSeries(
                3,
                time_grid,
                [selection_access_decision(3, 3, time_index) for time_index in 1:time_count(time_grid)],
            ),
        ],
    )

    scores = score_energy_drain_attack_endpoints(
        isl_series,
        access_table,
        3;
        candidate_ground_ids = [1, 2, 3],
        target_satellite_id = 2,
        start_elapsed_s = 0,
        end_elapsed_s = 20,
        rate_mbps = 100,
        flows_per_pair = 1,
        power_model = CommunicationPowerModel(gsl_w_per_mbps = 1, isl_tx_w_per_mbps = 1, isl_rx_w_per_mbps = 1),
    )
    best = first(scores)

    @test length(scores) == 6
    @test best.target_satellite_id == 2
    @test (best.source_ground_id, best.destination_ground_id) in [(1, 3), (3, 1)]
    @test best.target_communication_load_w_s == 4000
    @test best.peak_target_communication_load_w == 200
    @test select_energy_drain_attack_endpoint(
        isl_series,
        access_table,
        3;
        candidate_ground_ids = [1, 2, 3],
        target_satellite_id = 2,
        start_elapsed_s = 0,
        end_elapsed_s = 20,
        rate_mbps = 100,
        power_model = CommunicationPowerModel(gsl_w_per_mbps = 1, isl_tx_w_per_mbps = 1, isl_rx_w_per_mbps = 1),
    ).source_ground_id == best.source_ground_id

    config_from_score = energy_drain_attack_config_from_score(
        best;
        id_start = 50,
        start_elapsed_s = 0,
        end_elapsed_s = 20,
        rate_mbps = 100,
        flows_per_pair = 2,
    )
    @test config_from_score.source_ground_ids == [best.source_ground_id]
    @test config_from_score.destination_ground_ids == [best.destination_ground_id]
    @test length(energy_drain_attack_demands(config_from_score)) == 2
end

@testset "makie viewer" begin
    metadata = SourceMetadata("viewer-fixture")
    elements = DesignOrbitElementSet(altitude_km = 550, inclination_deg = 53, metadata = metadata)
    sat = Satellite(
        identifier = SatelliteId(
            global_id = 1,
            shell_id = 1,
            shell_local_id = 1,
            orbit_plane_id = 1,
            plane_local_slot = 1,
        ),
        orbit_elements = elements,
    )
    constellation = Constellation(
        "ViewerFixture",
        [Shell(id = 1, name = "shell1", orbit_planes = [OrbitPlane(1, 1, 0, [sat])])],
        metadata,
    )
    time_grid = SimulationTimeGrid(SimulationEpoch(DateTime(2026, 1, 1), TimeUTC), 10, 10)
    ephemeris = ConstellationEphemeris(
        "ViewerFixture",
        time_grid,
        [
            SatelliteEphemeris(
                1,
                [
                    EphemerisSample(
                        satellite_id = 1,
                        time_index = 1,
                        elapsed_s = 0,
                        cartesian = CartesianState(
                            ECEF,
                            (WGS84_EQUATORIAL_RADIUS_KM + 550.0, 0.0, 0.0),
                            nothing,
                        ),
                        geodetic = GeodeticPosition(0, 0, 550),
                    ),
                    EphemerisSample(
                        satellite_id = 1,
                        time_index = 2,
                        elapsed_s = 10,
                        cartesian = CartesianState(
                            ECEF,
                            (WGS84_EQUATORIAL_RADIUS_KM + 550.0, 100.0, 0.0),
                            nothing,
                        ),
                        geodetic = GeodeticPosition(0, 1, 550),
                    ),
                ],
            ),
        ],
    )
    ground = GroundStation(1, "Equator", GeodeticPosition(0, 0, 0))
    figure = plot_makie_viewer(
        constellation,
        ephemeris;
        ground_stations = [ground],
        config = MakieViewerConfig(title = "Makie Viewer Test"),
    )

    @test figure isa GLMakie.Figure
    @test_throws ArgumentError MakieViewerConfig(time_index = 0)
    @test_throws ArgumentError MakieViewerConfig(satellite_markersize = 0)
    @test_throws ArgumentError MakieViewerConfig(playback_interval_ms = 0)
    @test_throws ArgumentError plot_makie_viewer(
        constellation,
        ephemeris;
        config = MakieViewerConfig(time_index = 3),
    )
end

@testset "orbit viewer geography layer" begin
    geography = SatelliteSimJulia.GeographyLayer(
        [[(-1.0, 0.0), (1.0, 0.0), (1.0, 1.0), (-1.0, 0.0)]],
        [[(10.0, 10.0), (11.0, 10.0), (11.0, 11.0), (10.0, 10.0)]],
        [
            SatelliteSimJulia.CountryRegion(
                "Fixtureland",
                [[(-2.0, -2.0), (2.0, -2.0), (2.0, 2.0), (-2.0, 2.0), (-2.0, -2.0)]],
            ),
        ],
        [
            SatelliteSimJulia.CityLabel("Near", 0.2, 0.2, 1000),
            SatelliteSimJulia.CityLabel("Far", 45.0, 45.0, 2000),
        ],
    )

    boundary_points = SatelliteSimJulia.geography_boundary_points(geography, 0)
    urban_points = SatelliteSimJulia.geography_urban_area_points(geography, 0)
    city_points = SatelliteSimJulia.global_city_points(geography, 0, 1)
    labels = SatelliteSimJulia.nearest_city_labels(geography, GeodeticPosition(0.0, 0.0, 0.0), 1)
    subpoint = GeodeticPosition(0.0, 0.0, 0.0)

    @test !isempty(boundary_points)
    @test !isempty(urban_points)
    @test length(city_points) == 1
    @test only(labels).name == "Near"
    @test SatelliteSimJulia.nearest_city_label(geography, subpoint).name == "Near"
    @test SatelliteSimJulia.country_at_subpoint(geography, subpoint) == "Fixtureland"
    @test occursin("Fixtureland", SatelliteSimJulia.subpoint_summary(geography, subpoint))
    @test SatelliteSimJulia.selected_satellite_id_value(nothing) == 0
    @test SatelliteSimJulia.selected_satellite_id_value(3) == 3
    @test SatelliteSimJulia.selected_satellite_id_from_value(0) === nothing
    @test SatelliteSimJulia.selected_satellite_id_from_value(3) == 3
    @test isempty(SatelliteSimJulia.global_city_points(geography, 0, 0))
    @test OrbitViewerConfig(max_global_city_points = 0).max_global_city_points == 0
    @test_throws ArgumentError OrbitViewerConfig(max_global_city_points = -1)
end

@testset "propagator interface" begin
    metadata = SourceMetadata("unit-test")
    elements = DesignOrbitElementSet(altitude_km = 550, inclination_deg = 53, metadata = metadata)
    sat1 = Satellite(
        identifier = SatelliteId(
            global_id = 1,
            shell_id = 1,
            shell_local_id = 1,
            orbit_plane_id = 1,
            plane_local_slot = 1,
        ),
        orbit_elements = elements,
    )
    sat2 = Satellite(
        identifier = SatelliteId(
            global_id = 2,
            shell_id = 1,
            shell_local_id = 2,
            orbit_plane_id = 1,
            plane_local_slot = 2,
        ),
        orbit_elements = elements,
    )
    plane = OrbitPlane(1, 1, 0, [sat1, sat2])
    shell = Shell(id = 1, name = "shell1", altitude_km = 550, inclination_deg = 53, orbit_planes = [plane])
    constellation = Constellation("Fixture", [shell], metadata)
    time_grid = SimulationTimeGrid(SimulationEpoch(DateTime(2026, 1, 1), TimeUTC), 10, 5)
    propagator = FixturePropagator()

    @test supports_orbit_elements(propagator, elements)
    @test !supports_orbit_elements(propagator, TLEOrbitElementSet(
        "SAT",
        "1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753",
        "2 00005  34.2682 331.5174 1859667 331.7664  19.3264 10.82419157413667",
    ))

    sat_ephemeris = propagate_satellite(propagator, sat1, time_grid)
    @test sat_ephemeris.satellite_id == 1
    @test length(sat_ephemeris) == time_count(time_grid)
    @test sat_ephemeris[2].elapsed_s == 5
    @test sat_ephemeris[2].cartesian.position_km == (1.0, 5.0, 2.0)

    constellation_ephemeris = propagate_constellation(propagator, constellation, time_grid)
    @test constellation_ephemeris.constellation_name == "Fixture"
    @test length(constellation_ephemeris) == 2
    @test constellation_ephemeris[sat2][3].elapsed_s == 10
    @test length(ephemeris_samples(constellation_ephemeris)) == 6

    transform = SimpleTemeToGeodeticTransform()
    @test_throws ArgumentError attach_geodetic(constellation_ephemeris, transform)

    tle_sat = Satellite(
        identifier = SatelliteId(
            global_id = 3,
            shell_id = 1,
            shell_local_id = 3,
            orbit_plane_id = 1,
            plane_local_slot = 3,
        ),
        orbit_elements = TLEOrbitElementSet(
            "SAT",
            "1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753",
            "2 00005  34.2682 331.5174 1859667 331.7664  19.3264 10.82419157413667",
        ),
    )
    @test_throws ArgumentError propagate_satellite(propagator, tle_sat, time_grid)
end

@testset "sgp4 propagator adapter" begin
    metadata = SourceMetadata("unit-test")
    tle_elements = TLEOrbitElementSet(
        "VANGUARD 1",
        "1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753",
        "2 00005  34.2682 331.5174 1859667 331.7664  19.3264 10.82419157413661",
        metadata = metadata,
    )
    satellite = Satellite(
        identifier = SatelliteId(
            global_id = 1,
            shell_id = 1,
            shell_local_id = 1,
            orbit_plane_id = 1,
            plane_local_slot = 1,
        ),
        orbit_elements = tle_elements,
    )
    time_grid = SimulationTimeGrid(
        SimulationEpoch(DateTime(2000, 6, 27, 18, 50, 19, 734), TimeUTC),
        60,
        60,
    )
    propagator = Sgp4PropagatorAdapter()

    @test supports_orbit_elements(propagator, tle_elements)

    sample = propagate_sample(propagator, satellite, time_grid, 1)
    @test sample.satellite_id == 1
    @test sample.time_index == 1
    @test sample.elapsed_s == 0
    @test sample.cartesian.frame == TEME
    @test sample.cartesian.position_km[1] ≈ 6293.994 atol = 0.2
    @test sample.cartesian.velocity_km_s[2] ≈ 5.55895 atol = 1e-3

    ephemeris = propagate_satellite(propagator, satellite, time_grid)
    @test length(ephemeris) == 2
    @test ephemeris[2].elapsed_s == 60
    @test ephemeris[2].cartesian.frame == TEME

    transform = SimpleTemeToGeodeticTransform()
    ecef_sample = teme_to_ecef(transform, sample.cartesian, target_datetime(time_grid, sample.elapsed_s))
    @test ecef_sample.frame == ECEF
    @test ecef_sample.velocity_km_s !== nothing

    sample_with_geodetic = attach_geodetic(sample, transform, time_grid)
    @test sample_with_geodetic.cartesian === sample.cartesian
    @test sample_with_geodetic.geodetic !== nothing
    @test -90 <= sample_with_geodetic.geodetic.latitude_deg <= 90
    @test -180 <= sample_with_geodetic.geodetic.longitude_deg <= 180
    @test sample_with_geodetic.geodetic.altitude_km > 0

    enriched_ephemeris = attach_geodetic(ephemeris, transform, time_grid)
    @test enriched_ephemeris[1].geodetic !== nothing
    @test enriched_ephemeris[2].geodetic !== nothing

    bad_checksum = TLEOrbitElementSet(
        "VANGUARD 1",
        "1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753",
        "2 00005  34.2682 331.5174 1859667 331.7664  19.3264 10.82419157413667",
        metadata = metadata,
    )
    bad_satellite = Satellite(
        identifier = SatelliteId(
            global_id = 2,
            shell_id = 1,
            shell_local_id = 2,
            orbit_plane_id = 1,
            plane_local_slot = 2,
        ),
        orbit_elements = bad_checksum,
    )
    @test_logs (:error, r"Wrong checksum") @test_throws ArgumentError propagate_sample(
        propagator,
        bad_satellite,
        time_grid,
        1,
    )

    unchecked = Sgp4PropagatorAdapter(verify_checksum = false)
    unchecked_sample = propagate_sample(unchecked, bad_satellite, time_grid, 1)
    @test unchecked_sample.cartesian.frame == TEME
end

@testset "earth-fixed node propagator" begin
    elements = EarthFixedOrbitElementSet(
        altitude_km = 550,
        inclination_deg = 0,
        raan_deg = 0,
        mean_anomaly_deg = 0,
    )
    node = Satellite(
        identifier = SatelliteId(
            global_id = 1,
            shell_id = 1,
            shell_local_id = 1,
            orbit_plane_id = 1,
            plane_local_slot = 1,
        ),
        name = "GROUND-NODE-1",
        orbit_elements = elements,
    )
    epoch = SimulationEpoch(DateTime(2026, 1, 1), TimeUTC)
    time_grid = SimulationTimeGrid(epoch, 86_164, 86_164)
    propagator = EarthFixedNodePropagator()

    @test supports_orbit_elements(propagator, elements)

    sample = propagate_sample(propagator, node, time_grid, 1)
    @test sample.cartesian.frame == TEME
    @test LinearAlgebra.norm(sample.cartesian.position_km) ≈ WGS84_EQUATORIAL_RADIUS_KM + 550 atol = 1e-3
    @test LinearAlgebra.norm(sample.cartesian.velocity_km_s) ≈ 0.505 atol = 1e-3
    @test LinearAlgebra.norm(sample.cartesian.velocity_km_s) ≈
        (WGS84_EQUATORIAL_RADIUS_KM + 550) * 7.292115146706979e-5 atol = 1e-12

    second_grid = SimulationTimeGrid(epoch, 2, 1)
    first_second_samples = [
        propagate_sample(propagator, node, second_grid, time_index)
        for time_index in 1:3
    ]
    finite_difference_velocity = (
        collect(first_second_samples[3].cartesian.position_km) -
        collect(first_second_samples[1].cartesian.position_km)
    ) ./ 2
    @test LinearAlgebra.norm(
        finite_difference_velocity - collect(first_second_samples[2].cartesian.velocity_km_s),
    ) < 3e-6

    transform = SimpleTemeToGeodeticTransform()
    roundtrip_ecef = teme_to_ecef(
        transform,
        first_second_samples[2].cartesian,
        target_datetime(second_grid, first_second_samples[2].elapsed_s),
    )
    @test LinearAlgebra.norm(
        collect(roundtrip_ecef.position_km) - earth_fixed_node_position_ecef_km(elements),
    ) < 1e-9

    inclined_elements = EarthFixedOrbitElementSet(
        altitude_km = 550,
        inclination_deg = 53,
        raan_deg = 10,
        argument_of_perigee_deg = 5,
        mean_anomaly_deg = 20,
    )
    inclined_node = Satellite(
        identifier = SatelliteId(
            global_id = 2,
            shell_id = 1,
            shell_local_id = 2,
            orbit_plane_id = 1,
            plane_local_slot = 2,
        ),
        name = "GROUND-NODE-2",
        orbit_elements = inclined_elements,
    )
    inclined_sample = propagate_sample(propagator, inclined_node, time_grid, 1)
    inclined_fixed_position = earth_fixed_node_position_ecef_km(inclined_elements)
    spin_radius_km = LinearAlgebra.norm(inclined_fixed_position[1:2])
    @test earth_fixed_node_longitude_deg(inclined_elements) ≈ 35.0
    @test LinearAlgebra.norm(inclined_sample.cartesian.velocity_km_s) ≈
        spin_radius_km * 7.292115146706979e-5 atol = 1e-12

    ephemeris = propagate_satellite(propagator, node, time_grid)
    @test length(ephemeris) == 2
    @test ephemeris[2].elapsed_s == 86_164
    @test LinearAlgebra.norm(ephemeris[2].cartesian.position_km) ≈
        LinearAlgebra.norm(sample.cartesian.position_km) atol = 1e-6
    @test LinearAlgebra.norm(ephemeris[2].cartesian.position_km .- sample.cartesian.position_km) < 1.0

    tle_node = Satellite(
        identifier = SatelliteId(
            global_id = 2,
            shell_id = 1,
            shell_local_id = 2,
            orbit_plane_id = 1,
            plane_local_slot = 2,
        ),
        orbit_elements = TLEOrbitElementSet(
            "SAT",
            "1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753",
            "2 00005  34.2682 331.5174 1859667 331.7664  19.3264 10.82419157413667",
        ),
    )
    @test_throws ArgumentError propagate_sample(propagator, tle_node, time_grid, 1)
end

# ===== 攻防对抗层测试（P0）=====
include(joinpath(@__DIR__, "test_security.jl"))

# ===== 攻防对抗层 P1 端到端测试 =====
include(joinpath(@__DIR__, "test_security_p1.jl"))

# ===== 链路层：ITU-R P.618 雨衰模型测试 =====
include(joinpath(@__DIR__, "test_rain_attenuation.jl"))

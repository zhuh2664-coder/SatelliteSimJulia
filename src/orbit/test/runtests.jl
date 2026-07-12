using Dates
using SatelliteSimOrbit
using SatelliteSimFoundation
using SatelliteSimBackends
using Test
using JSON
import SatelliteToolbox

struct ContractBackend <: SatelliteSimBackends.AbstractOrbitBackend end

SatelliteSimBackends.propagate_orbit(::ContractBackend, elements, times; kwargs...) =
    SatelliteSimBackends.OrbitResult(
        reshape(collect(1.0:(length(elements) * length(times) * 3)), length(elements), length(times), 3),
        Dict{String,Any}("backend" => "contract-test"),
    )

@testset "SatelliteSimOrbit" begin

    @testset "Walker 星座生成" begin
        elems = generate_walker_delta(; T=6, P=2, F=0, alt_km=550.0, inc_deg=53.0)
        @test length(elems) == 6
        @test all(e -> e isa typeof(elems[1]), elems)
    end

    @testset "TwoBody 传播 → ECEF 位置矩阵" begin
        elems = generate_walker_delta(; T=6, P=2, F=0, alt_km=550.0, inc_deg=53.0)
        pos = propagate_to_ecef(elems, [0.0, 60.0, 120.0]; propagator=TwoBodyPropagator())
        @test size(pos) == (6, 3, 3)
        @test all(isfinite, pos)
        norms = [sqrt(sum(pos[i,t,:].^2)) for i in 1:6, t in 1:3]
        @test all(n -> 6800.0 < n < 7100.0, norms)
    end

    @testset "传播器类型" begin
        @test TwoBodyPropagator() isa AbstractKeplerianPropagator
        @test J2Propagator() isa AbstractKeplerianPropagator
        @test J4Propagator() isa AbstractKeplerianPropagator
    end

    @testset "访问器函数" begin
        elems = generate_walker_delta(; T=6, P=2, F=0, alt_km=550.0, inc_deg=53.0)
        pos = propagate_to_ecef(elems, [0.0, 60.0]; propagator=TwoBodyPropagator())
        @test n_satellites(pos) == 6
        @test n_timesteps(pos) == 2
        @test size(positions_at_last(pos)) == (6, 3)
        @test size(position_at_instant(pos, 1)) == (6, 3)
    end

end

@testset "Orbit element schema contracts" begin
    design = DesignOrbitElementSet(
        altitude_km = 550,
        inclination_deg = 53,
        raan_deg = 10,
        argument_of_perigee_deg = 5,
        mean_anomaly_deg = 20,
    )
    @test design.altitude_km == 550.0
    @test design.inclination_deg == 53.0
    @test design.raan_deg == 10.0
    @test design.argument_of_perigee_deg == 5.0
    @test design.mean_anomaly_deg == 20.0
    @test design.eccentricity == 0.001

    @test_throws ArgumentError DesignOrbitElementSet(altitude_km = -1, inclination_deg = 53)
    @test_throws ArgumentError DesignOrbitElementSet(altitude_km = 550, inclination_deg = 181)
    @test_throws ArgumentError DesignOrbitElementSet(altitude_km = 550, inclination_deg = 53, eccentricity = 1.0)

    earth_fixed = EarthFixedOrbitElementSet(
        altitude_km = 0,
        latitude_deg = 40,
        longitude_deg = -75,
    )
    @test earth_fixed.latitude_deg == 40.0
    @test earth_fixed.longitude_deg == -75.0
    @test earth_fixed.inclination_deg == 40.0
    @test earth_fixed.mean_motion_rev_per_day ≈ EARTH_FIXED_ROTATION_REV_PER_DAY
    @test earth_fixed_node_longitude_deg(earth_fixed) == -75.0

    legacy_earth_fixed = EarthFixedOrbitElementSet(
        altitude_km = 550,
        inclination_deg = 53,
        raan_deg = 10,
        argument_of_perigee_deg = 5,
        mean_anomaly_deg = 20,
    )
    @test legacy_earth_fixed.latitude_deg == 53.0
    @test legacy_earth_fixed.longitude_deg == 35.0
    @test earth_fixed_node_longitude_deg(legacy_earth_fixed) == 35.0

    western_longitude = EarthFixedOrbitElementSet(longitude_deg = -75)
    @test western_longitude.longitude_deg == -75.0
    @test earth_fixed_node_position_ecef_km(western_longitude) isa Vector{Float64}

    @test_throws ArgumentError EarthFixedOrbitElementSet(altitude_km = -1)
    @test_throws ArgumentError EarthFixedOrbitElementSet(latitude_deg = 91)
    @test_throws ArgumentError EarthFixedOrbitElementSet(eccentricity = 0.1)

    tle = TLEOrbitElementSet(
        "SAT",
        "1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753",
        "2 00005  34.2682 331.5174 1859667 331.7664  19.3264 10.82419157413667",
    )
    @test tle.name == "SAT"
    @test tle.satellite_name == "SAT"
    @test tle.metadata.source == "tle"
    @test_throws ArgumentError TLEOrbitElementSet("bad", "x", "2 ok")
end

@testset "EarthFixedNodePropagator uses Foundation geodetic conversion" begin
    elements = EarthFixedOrbitElementSet(altitude_km = 550, latitude_deg = 0, longitude_deg = 0)
    node = Satellite(id = 1, name = "ground-node", orbit = elements, config = SatelliteConfig())
    epoch = SimulationEpoch(DateTime(2026, 1, 1), SatelliteSimFoundation.TimeUTC)
    time_grid = SimulationTimeGrid(epoch, 2, 1)
    propagator = EarthFixedNodePropagator()

    @test supports_orbit_elements(propagator, elements)
    sample = propagate_sample(propagator, node, time_grid, 1)
    @test sample.cartesian.frame == TEME
    @test sample.elapsed_s == 0

    transform = SimpleTemeToGeodeticTransform()
    ecef = teme_to_ecef(transform, sample.cartesian, target_datetime(time_grid, sample.elapsed_s))
    expected = earth_fixed_node_position_ecef_km(elements)
    @test maximum(abs.(collect(ecef.position_km) .- expected)) < 1e-6
end

@testset "Orbit accessors preserve view semantics" begin
    positions = reshape(collect(Float64, 1:18), 3, 2, 3)
    instant = position_at_instant(positions, 1)
    sat_track = satellite_positions(positions, 1)

    @test instant isa AbstractMatrix{Float64}
    @test sat_track isa AbstractMatrix{Float64}
    instant[1, 1] = -99.0
    @test positions[1, 1, 1] == -99.0
    sat_track[1, 1] = -42.0
    @test positions[1, 1, 1] == -42.0
end

@testset "Optional backend dispatch preserves the ECEF array contract" begin
    elements = [:one, :two]
    times = 0:10:20
    result = propagate_with_backend(ContractBackend(), elements, times)
    positions = propagate_to_ecef(ContractBackend(), elements, times)

    @test size(result.positions_ecef_km) == (2, 3, 3)
    @test positions == result.positions_ecef_km
    @test n_satellites(positions) == 2
    @test n_timesteps(positions) == 3
end

@testset "OMM/GP JSON 9位目录号与 SGP4 裸数组桥接" begin
    tle_path = joinpath(@__DIR__, "..", "..", "..", "data", "tle", "celestrak", "starlink_gp_latest.tle")
    lines = readlines(tle_path)
    tle_specs = TLEOrbitElementSet[]
    tle_objects = SatelliteToolbox.TLE[]
    for i in 1:2
        name = strip(lines[3i - 2])
        l1 = strip(lines[3i - 1])
        l2 = strip(lines[3i])
        push!(tle_specs, TLEOrbitElementSet(name, l1, l2))
        push!(tle_objects, SatelliteToolbox.read_tle(l1, l2; name = name, verify_checksum = false))
    end

    function tle_to_omm_row(tle::SatelliteToolbox.TLE, name)
        # 用完整精度的儒略日作为 EPOCH，避免 TLE 的 DateTime 毫秒化简导致 OMM/TLE 路径出现秒级以下偏差。
        jd = SatelliteToolbox.tle_epoch(tle)
        return Dict{String,Any}(
            "OBJECT_NAME" => name,
            "OBJECT_ID" => tle.international_designator,
            "EPOCH" => jd,
            "NORAD_CAT_ID" => tle.satellite_number,
            "MEAN_MOTION" => tle.mean_motion,
            "ECCENTRICITY" => tle.eccentricity,
            "INCLINATION" => tle.inclination,
            "RA_OF_ASC_NODE" => tle.raan,
            "ARG_OF_PERICENTER" => tle.argument_of_perigee,
            "MEAN_ANOMALY" => tle.mean_anomaly,
            "BSTAR" => tle.bstar,
            "MEAN_MOTION_DOT" => tle.dn_o2,
            "MEAN_MOTION_DDOT" => tle.ddn_o6,
            "CLASSIFICATION_TYPE" => string(tle.classification),
            "ELEMENT_SET_NO" => tle.element_set_number,
            "REV_AT_EPOCH" => tle.revolution_number,
        )
    end

    omm_json = JSON.json([tle_to_omm_row(tle, spec.name) for (tle, spec) in zip(tle_objects, tle_specs)])
    omm_elements = read_omm_json(omm_json)
    @test length(omm_elements) == 2
    @test all(e -> e isa OMMOrbitElementSet, omm_elements)
    @test omm_elements[1].name == tle_specs[1].name
    @test omm_elements[1].object_id == tle_objects[1].international_designator

    # 以第一颗 TLE 的 epoch 为起点，取 0/60/120 秒三个时刻
    epoch_dt = SatelliteToolbox.tle_epoch(DateTime, tle_objects[1])
    epoch = SimulationEpoch(epoch_dt, SatelliteSimFoundation.TimeUTC)
    grid = SimulationTimeGrid(epoch, 120, 60)

    pos_omm = propagate_to_ecef(omm_elements, grid)
    pos_tle = propagate_to_ecef(tle_specs, grid; verify_checksum = false)

    @test size(pos_omm) == (2, 3, 3)
    @test size(pos_tle) == (2, 3, 3)
    max_err = maximum(abs.(pos_omm .- pos_tle))
    @test max_err < 1e-6
    @test all(isfinite, pos_omm)

    # 9 位目录号解析：直接绕开 TLE 5 位限制
    row9 = tle_to_omm_row(tle_objects[1], tle_specs[1].name)
    row9["NORAD_CAT_ID"] = 123456789
    el9 = read_omm_json(JSON.json([row9]))[1]
    @test el9 isa OMMOrbitElementSet
    @test el9.norad_cat_id == 123456789
    @test el9.name == tle_specs[1].name

    # 异常路径：缺字段 / 坏 epoch
    bad = copy(row9)
    delete!(bad, "MEAN_MOTION")
    @test_throws ArgumentError read_omm_json(JSON.json([bad]))

    bad = copy(row9)
    bad["EPOCH"] = "not-a-date"
    @test_throws ArgumentError read_omm_json(JSON.json([bad]))

    # Celestrak 真实 GP JSON 的 EPOCH 带 6 位小数秒（微秒），超出 DateTime 毫秒精度，
    # 必须能解析且保留亚毫秒部分（Float64 JD 分辨率约 40 µs）。
    row_us = tle_to_omm_row(tle_objects[1], tle_specs[1].name)
    row_us["EPOCH"] = "2026-06-08T06:35:32.842624"
    el_us = read_omm_json(JSON.json([row_us]))[1]
    expected_jd = 2451545.0 +
        Dates.value(DateTime(2026, 6, 8, 6, 35, 32) - DateTime(2000, 1, 1, 12, 0, 0)) / 86400000.0 +
        0.842624 / 86400.0
    @test isapprox(el_us.epoch_jd, expected_jd; atol = 1e-9)

    # 文件数据源：OMMJsonFileSource + load_omm_records（JSON.parsefile 分支）
    mktempdir() do dir
        path = joinpath(dir, "gp.json")
        write(path, omm_json)
        source = OMMJsonFileSource("celestrak-gp", path)
        @test omm_source_id(source) == "celestrak-gp"
        records = load_omm_records(source)
        @test length(records) == 2
        @test records[1].norad_cat_id == omm_elements[1].norad_cat_id
        @test records[1].epoch_jd == omm_elements[1].epoch_jd
        @test_throws ArgumentError load_omm_records(OMMJsonFileSource("missing", joinpath(dir, "nope.json")))
        @test_throws ArgumentError OMMJsonFileSource("", path)
    end
end

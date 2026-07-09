#!/usr/bin/env julia

using JSON
using SatelliteSimLab
using Test

function _read_header(path)
    return split(readline(path), ',')
end

function _write_tle_fixture(path::AbstractString)
    open(path, "w") do io
        println(io, "SAT-A")
        println(io, "1 00001U 20001A   26001.00000000  .00000000  00000-0  00000-0 0  0001")
        println(io, "2 00001  53.0000   0.0000 0001000   0.0000   0.0000 15.00000000    01")
        println(io, "SAT-B")
        println(io, "1 00002U 20001B   26001.00000000  .00000000  00000-0  00000-0 0  0002")
        println(io, "2 00002  53.0000  20.0000 0001000   0.0000  90.0000 15.00000000    02")
    end
    return path
end

function _fixture_positions()
    positions = zeros(Float64, 4, 2, 3)
    positions[1, 1, :] .= (7000.0, 0.0, 0.0)
    positions[2, 1, :] .= (7001.0, 0.0, 0.0)
    positions[4, 1, :] .= (7002.0, 0.0, 0.0)
    positions[3, 1, :] .= (7100.0, 0.0, 0.0)

    positions[1, 2, :] .= (7000.0, 0.0, 0.0)
    positions[3, 2, :] .= (7001.0, 0.0, 0.0)
    positions[4, 2, :] .= (7002.0, 0.0, 0.0)
    positions[2, 2, :] .= (7100.0, 0.0, 0.0)
    return positions
end

@testset "ns-3 and STK neutral exporters" begin
    positions = _fixture_positions()
    constraints = SatelliteSimLab.PhysicalConstraints(
        isl_max_range_km = 1_000.0,
        isl_require_los = false,
        isl_max_capacity_mbps = 100.0,
    )
    ground_stations = [
        SatelliteSimLab.GroundStation(
            id = 1,
            name = "source",
            position = SatelliteSimLab.GeodeticPosition(0.0, 0.0, 0.0),
        ),
        SatelliteSimLab.GroundStation(
            id = 4,
            name = "destination",
            position = SatelliteSimLab.GeodeticPosition(0.0, 180.0, 0.0),
        ),
    ]
    demands = SatelliteSimLab.TrafficDemand[
        SatelliteSimLab.TrafficDemand(
            id = 1,
            source_ground_id = 1,
            destination_ground_id = 4,
            start_elapsed_s = 0,
            end_elapsed_s = 120,
            rate_mbps = 50.0,
        ),
    ]
    frames = SatelliteSimLab.assess_temporal_flow_routes(
        positions,
        4,
        1,
        t -> SatelliteSimLab.NearestNeighborStrategy(positions = positions, k = 1, time_step = t),
        constraints,
        demands,
        SatelliteSimLab.DijkstraRouting();
        elapsed_by_time = [0, 60],
    )

    mktempdir() do tmp
        ns3_dir = joinpath(tmp, "ns3")
        ns3_result = SatelliteSimLab.export_ns3_trace(
            ns3_dir;
            positions = positions,
            frames = frames,
            demands = demands,
            ground_stations = ground_stations,
            scenario_name = "probe_fixture_ns3",
        )

        @test ns3_result["satellite_count"] == 4
        @test ns3_result["ground_node_count"] == 2
        @test ns3_result["demand_count"] == 1
        @test isfile(joinpath(ns3_dir, "scenario_manifest.json"))
        @test isfile(joinpath(ns3_dir, "nodes.csv"))
        @test isfile(joinpath(ns3_dir, "traffic.csv"))
        @test isfile(joinpath(ns3_dir, "links_t001.csv"))
        @test isfile(joinpath(ns3_dir, "routes_t001.csv"))
        @test _read_header(joinpath(ns3_dir, "links_t001.csv"))[1:5] ==
              ["time_index", "elapsed_s", "link_id", "src_node_id", "dst_node_id"]
        ns3_manifest = JSON.parsefile(joinpath(ns3_dir, "scenario_manifest.json"))
        @test ns3_manifest["schema"] == "satellitesim_ns3_trace_v1"
        @test ns3_manifest["time_step_count"] == 2
        @test length(readlines(joinpath(ns3_dir, "traffic.csv"))) == length(demands) + 1

        tle_path = _write_tle_fixture(joinpath(tmp, "fixture.tle"))
        stk_dir = joinpath(tmp, "stk")
        stk_result = SatelliteSimLab.export_stk_scenario(
            stk_dir;
            tle_path = tle_path,
            max_sats = 2,
            ground_stations = ground_stations,
            access_requests = demands,
            scenario_name = "probe_fixture_stk",
        )

        @test stk_result["satellite_count"] == 2
        @test stk_result["facility_count"] == 2
        @test stk_result["access_request_count"] == 1
        @test isfile(joinpath(stk_dir, "scenario_metadata.json"))
        @test isfile(joinpath(stk_dir, "satellites.tle"))
        @test isfile(joinpath(stk_dir, "facilities.csv"))
        @test isfile(joinpath(stk_dir, "access_requests.csv"))
        @test isfile(joinpath(stk_dir, "report_inputs.md"))
        @test length(readlines(joinpath(stk_dir, "satellites.tle"))) == 2 * 3
        @test length(readlines(joinpath(stk_dir, "access_requests.csv"))) == length(demands) + 1
        stk_manifest = JSON.parsefile(joinpath(stk_dir, "scenario_metadata.json"))
        @test stk_manifest["schema"] == "satellitesim_stk_bundle_v1"
    end
end

println("NS3 STK EXPORTERS: ALL PASS")

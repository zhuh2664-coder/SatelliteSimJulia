#!/usr/bin/env julia

using Test
using SatelliteSimCore
using SatelliteSimNet
using SatelliteSimTraffic
using SatelliteSimLab
using SatelliteSimViz

@testset "Viz temporal route PNG artifacts" begin
    # Probe-only internal bypass: avoids GeoMakie/NaturalEarth download noise.
    SatelliteSimViz._coastline_cache[] = :builtin
    SatelliteSimViz._coastline_source[] = :builtin

    n_sat = 4
    n_planes = 1
    positions = zeros(Float64, n_sat, 2, 3)

    positions[1, 1, :] .= (7000.0, 0.0, 0.0)
    positions[2, 1, :] .= (7001.0, 0.0, 0.0)
    positions[4, 1, :] .= (7002.0, 0.0, 0.0)
    positions[3, 1, :] .= (7100.0, 0.0, 0.0)

    positions[1, 2, :] .= (7000.0, 0.0, 0.0)
    positions[3, 2, :] .= (7001.0, 0.0, 0.0)
    positions[4, 2, :] .= (7002.0, 0.0, 0.0)
    positions[2, 2, :] .= (7100.0, 0.0, 0.0)

    constraints = PhysicalConstraints(
        isl_max_range_km=1_000.0,
        isl_require_los=false,
    )
    demand = TrafficDemand(
        id=1,
        source_ground_id=1,
        destination_ground_id=4,
        start_elapsed_s=0,
        end_elapsed_s=120,
        rate_mbps=50.0,
    )

    frames = assess_temporal_flow_routes(
        positions,
        n_sat,
        n_planes,
        t -> NearestNeighborStrategy(positions=positions, k=1, time_step=t),
        constraints,
        [demand],
        DijkstraRouting();
        elapsed_by_time = [0, 60],
    )

    @test frames[1].routes[1].path == [1, 2, 4]
    @test frames[2].routes[1].path == [1, 3, 4]

    outdir = mktempdir()
    paths = String[]
    for t in 1:2
        frame = frames[t]
        config = MakieViewerConfig(;
            title="Temporal route artifact frame $t",
            time_index=t,
            show_orbits=false,
            show_isl=true,
            show_route=true,
            show_ground_stations=false,
            dark_theme=false,
            route_linewidth=5.0,
        )
        out = joinpath(outdir, "temporal_route_t$(t).png")
        path = save_orbit_snapshot(
            out,
            positions;
            isl_pairs = frame.available_isl,
            isl_available = fill(true, length(frame.available_isl)),
            route_path = frame.routes[1].path,
            config = config,
        )
        push!(paths, path)
    end

    @test length(paths) == 2
    @test all(isfile, paths)
    @test all(path -> filesize(path) > 1000, paths)
end

println("VIZ TEMPORAL ROUTE ARTIFACT: ALL PASS")

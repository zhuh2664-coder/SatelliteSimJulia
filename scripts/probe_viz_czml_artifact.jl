#!/usr/bin/env julia

using JSON
using Test
using SatelliteSimViz

@testset "Viz CZML artifact probe" begin
    outdir = mktempdir()
    czml_path = joinpath(outdir, "probe.czml")

    pos = zeros(Float64, 2, 3, 3)
    pos[1, 1, :] .= (7000.0, 0.0, 0.0)
    pos[1, 2, :] .= (6000.0, 3500.0, 0.0)
    pos[1, 3, :] .= (3500.0, 6000.0, 0.0)
    pos[2, :, :] .= 1.1 .* pos[1, :, :]

    path = write_czml(czml_path, pos; dt=60.0, isl_pairs=[(1, 2)])
    packets = JSON.parsefile(path)

    @test path == czml_path
    @test isfile(czml_path)
    @test filesize(czml_path) > 100
    @test packets[1]["id"] == "document"
    @test any(packet -> get(packet, "id", "") == "satellite/1", packets)
    @test any(packet -> get(packet, "id", "") == "satellite/2", packets)
    @test any(packet -> occursin("isl", get(packet, "id", "")), packets)
    @test packets[2]["position"]["referenceFrame"] == "FIXED"
end

println("VIZ CZML ARTIFACT: ALL PASS")

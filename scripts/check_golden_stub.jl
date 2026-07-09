#!/usr/bin/env julia
# 夜间草稿：Stub 后端 golden 向量冒烟（不依赖 SatelliteToolbox）

using TOML
using Dates
using SatelliteSimStubBackend
using SatelliteSimBackends

const GOLDEN = joinpath(@__DIR__, "..", "test", "data", "golden", "stub_iridium_tle.toml")

function main()
    spec = TOML.parsefile(GOLDEN)
    lines = [spec["name"], spec["line1"], spec["line2"]]
    backend = StubOrbitBackend()
    tles = parse_tle_lines(backend, lines)
    epoch = DateTime(spec["epoch"])
    offsets = Int.(spec["offsets_s"])
    pos = propagate_sgp4(backend, tles, offsets; epoch)
    r = sqrt.(pos[1, :, 1] .^ 2 .+ pos[1, :, 2] .^ 2 .+ pos[1, :, 3] .^ 2)
    lo = Float64(spec["expected_radius_km_min"])
    hi = Float64(spec["expected_radius_km_max"])
    all(lo .< r .< hi) || error("golden radius out of range: $r")
    println("golden stub vectors: PASS")
end

main()

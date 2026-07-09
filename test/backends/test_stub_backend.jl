"""
test_stub_backend.jl — StubBackend 离线 CI 测试

验收标准（Phase 2.3）：
- StubBackend 可在无 SatelliteToolbox 的环境中加载
- propagate_sgp4 / propagate_keplerian 输出形状正确
- teme_to_geodetic 输出在合理范围内
- parse_tle_lines 解析标准 TLE 文本

运行方式（envs/core 或任意无 SatelliteToolbox 的环境）：
    julia test/backends/test_stub_backend.jl
"""

push!(LOAD_PATH, joinpath(@__DIR__, "..", "..", "src", "backends"))

include(joinpath(@__DIR__, "..", "..", "src", "backends", "StubBackend.jl"))
using .StubBackend
using Dates

const BACKEND = StubOrbitBackend()

# ── Iridium NEXT TLE 样例（公开数据）──────────────────────────────────────────
const TLE_LINES = [
    "IRIDIUM 100",
    "1 42804U 17039E   23001.50000000  .00000010  00000-0  20000-4 0  9991",
    "2 42804  86.3900 260.4200 0002100 273.9700  86.0800 14.34218526  1234",
]

function test_parse_tle()
    tles = StubBackend.OrbitBackend.parse_tle_lines(BACKEND, TLE_LINES)
    @assert length(tles) == 1 "Expected 1 TLE, got $(length(tles))"
    tle = tles[1]
    @assert tle.name == "IRIDIUM 100"
    @assert abs(tle.eccentricity - 0.00021) < 1e-4
    @assert abs(rad2deg(tle.inclination_rad) - 86.39) < 0.1
    println("  ✓ parse_tle_lines")
end

function test_propagate_sgp4()
    tles = StubBackend.OrbitBackend.parse_tle_lines(BACKEND, TLE_LINES)
    epoch = DateTime(2023, 1, 1, 12, 0, 0)
    offsets = collect(0:60:3600)  # 1h, 1-min steps → 61 time points
    pos = StubBackend.OrbitBackend.propagate_sgp4(BACKEND, tles, offsets; epoch)
    @assert size(pos) == (1, 61, 3) "Expected (1,61,3), got $(size(pos))"
    # 高度约 780 km（Iridium），裸数组应在 R_earth+500 ~ R_earth+900 km 范围
    r = sqrt.(pos[1,:,1].^2 .+ pos[1,:,2].^2 .+ pos[1,:,3].^2)
    @assert all(6700 .< r .< 7500) "Radius out of range: min=$(minimum(r)), max=$(maximum(r))"
    println("  ✓ propagate_sgp4 shape=$(size(pos)), r ∈ [$(round(minimum(r),digits=0)), $(round(maximum(r),digits=0))] km")
end

function test_propagate_keplerian()
    using .StubBackend.OrbitBackend: InternalKeplerianElements
    elem = InternalKeplerianElements(
        6928e3, 0.0, deg2rad(53.0), 0.0, 0.0, 0.0,
        DateTime(2023, 1, 1, 12, 0, 0),
    )
    epoch = DateTime(2023, 1, 1, 12, 0, 0)
    offsets = [0, 300, 600, 900]
    pos = StubBackend.OrbitBackend.propagate_keplerian(BACKEND, [elem], offsets; epoch)
    @assert size(pos) == (1, 4, 3)
    r = sqrt.(pos[1,:,1].^2 .+ pos[1,:,2].^2 .+ pos[1,:,3].^2)
    @assert all(abs.(r .- 6928.0) .< 10) "Radius error > 10 km: $r"
    println("  ✓ propagate_keplerian r ≈ $(round(mean(r),digits=1)) km")
end

function test_teme_to_geodetic()
    pos_teme = (6928.0, 0.0, 0.0)  # 赤道上方 ~550 km
    time = DateTime(2023, 1, 1, 12, 0, 0)
    lat, lon, alt = StubBackend.OrbitBackend.teme_to_geodetic(BACKEND, pos_teme, time)
    @assert -90 <= lat <= 90    "lat=$lat out of range"
    @assert -180 <= lon <= 180  "lon=$lon out of range"
    @assert 500 < alt < 600     "alt=$alt km unexpected"
    println("  ✓ teme_to_geodetic lat=$(round(lat,digits=1))° lon=$(round(lon,digits=1))° alt=$(round(alt,digits=1)) km")
end

mean(x) = sum(x) / length(x)

println("=== StubBackend 离线测试 ===")
test_parse_tle()
test_propagate_sgp4()
test_propagate_keplerian()
test_teme_to_geodetic()
println("=== 全部通过 ===")

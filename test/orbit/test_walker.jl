# test/orbit/test_walker.jl — Walker delta 星座生成测试

using SatelliteSimCore
using Test

@testset "Walker delta generation" begin
    T, P, F = 24, 6, 1
    elems = generate_walker_delta(T=T, P=P, F=F, alt_km=550.0, inc_deg=53.0)

    R_eq_m = WGS84_EQUATORIAL_RADIUS_KM * 1000.0

    @test length(elems) == T
    @test all(e -> e.a ≈ (R_eq_m + 550.0e3), elems)
    @test all(e -> e.e ≈ 0.001, elems)
    @test all(e -> e.i ≈ deg2rad(53.0), elems)

    # 每个轨道面卫星数 = T / P；Ω 为升交点赤经
    S = div(T, P)
    raan_groups = Dict{Float64, Vector{Float64}}()
    for e in elems
        raan = e.Ω
        ma = e.f
        push!(get!(raan_groups, raan, Float64[]), ma)
    end
    @test length(raan_groups) == P
    @test all(v -> length(v) == S, values(raan_groups))
end

@testset "Walker delta polar orbit RAAN span" begin
    # 极轨时 RAAN 展开 180°，非极轨 360°
    polar = generate_walker_delta(T=12, P=3, F=0, alt_km=600.0, inc_deg=90.0)
    raans = sort(unique(e.Ω for e in polar))
    @test isapprox(raans[end] - raans[1], deg2rad(120.0); atol=deg2rad(1.0))

    non_polar = generate_walker_delta(T=12, P=3, F=0, alt_km=600.0, inc_deg=53.0)
    raans = sort(unique(e.Ω for e in non_polar))
    @test isapprox(raans[end] - raans[1], deg2rad(240.0); atol=deg2rad(1.0))
end

@testset "Walker delta argument validation" begin
    @test_throws ArgumentError generate_walker_delta(T=0, P=1, F=0)
    @test_throws ArgumentError generate_walker_delta(T=24, P=5, F=1)
    @test_throws ArgumentError generate_walker_delta(T=24, P=6, F=6)
    @test_throws ArgumentError generate_walker_delta(T=25, P=6, F=1)
end

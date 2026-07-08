# test/link/test_gsl.jl — 地面站链路（GSL）可见性测试

using SatelliteSimJulia
using Test

@testset "evaluate_gsl_batch visible and invisible" begin
    R = WGS84_EQUATORIAL_RADIUS_KM
    h = 550.0

    # 2 颗卫星：1 颗在 (0°,0°) 天顶，1 颗在对跖点
    pos = Float64[
        R+h 0.0 0.0;
        -(R+h) 0.0 0.0
    ]
    gs = [(0.0, 0.0, 0.0)]
    avail, dist, elev, delay = evaluate_gsl_batch(pos, gs)

    @test size(avail) == (2, 1)
    @test avail[1, 1]
    @test !avail[2, 1]
    @test isapprox(dist[1, 1], h; atol=1.0)
    @test elev[1, 1] > 0.0
    @test elev[2, 1] < 0.0
    @test delay[1, 1] > 0.0
end

@testset "evaluate_gsl_batch multiple ground stations" begin
    R = WGS84_EQUATORIAL_RADIUS_KM
    h = 550.0

    pos = Float64[
        R+h 0.0 0.0;
        0.0 R+h 0.0
    ]
    # 地面站分别位于 (0°,0°) 与 (0°,90°E)
    gs = [(0.0, 0.0, 0.0), (0.0, 90.0, 0.0)]
    avail, _, _, _ = evaluate_gsl_batch(pos, gs)

    @test size(avail) == (2, 2)
    @test avail[1, 1]   # sat1 可见 gs1
    @test !avail[1, 2]  # sat1 不可见 gs2
    @test !avail[2, 1]  # sat2 不可见 gs1
    @test avail[2, 2]   # sat2 可见 gs2
end

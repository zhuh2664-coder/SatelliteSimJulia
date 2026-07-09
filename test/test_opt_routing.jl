# ===== Opt 路由数值修复（C5 aon_throughput）=====

using Test
using SatelliteSimJulia: aon_throughput

@testset "aon_throughput link_load" begin
    # 三角链 1-2-3，容量 1.0，三条 OD 各走最短路径 → 边 (1,2) 负载 2，(2,3) 负载 2
    A = fill(Inf, 3, 3)
    for i in 1:3; A[i, i] = 0.0; end
    A[1, 2] = A[2, 1] = 1000.0
    A[2, 3] = A[3, 2] = 1000.0

    throughput, n_overloaded = aon_throughput(A, 1.0; n_od_samples=500)
    @test throughput > 0
    @test n_overloaded > 0
end

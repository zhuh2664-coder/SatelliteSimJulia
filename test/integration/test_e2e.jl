# test/integration/test_e2e.jl — 端到端主路径工作流测试
#
# walker → propagate → topology → ISL → routing → GSL

using SatelliteSimJulia
using Test

@testset "End-to-end Walker → routing pipeline" begin
    # 1. 生成 Walker delta 星座（Iridium 量级 66/6，保证 ISL 可见）
    T, P, F = 66, 6, 2
    elems = generate_walker_delta(T=T, P=P, F=F, alt_km=780.0, inc_deg=86.4)
    @test length(elems) == T

    # 2. 传播到 ECEF
    tspan = collect(0.0:60.0:600.0)  # 11 步，每步 60s
    pos = propagate_to_ecef(elems, tspan; propagator=TwoBodyPropagator())
    @test size(pos) == (T, length(tspan), 3)

    # 检查轨道高度：第一颗卫星第一时刻位置模长 ≈ 地球半径 + 780 km
    r1 = sqrt(sum(abs2, pos[1, 1, :]))
    @test isapprox(r1, WGS84_EQUATORIAL_RADIUS_KM + 780.0; atol=50.0)

    # 3. 生成 GridPlus 拓扑
    topo = generate_topology(GridPlusStrategy(), T, P)
    links = vcat(topo.static_links, topo.dynamic_candidates)
    @test !isempty(links)

    # 4. 用最后时刻位置批量评估 ISL
    last_pos = pos[:, end, :]
    isl = evaluate_isl_batch(last_pos, links; constraints=LEO_DEFAULTS)
    navail = count(r -> r.available, isl)
    @test navail > 0
    @test navail <= length(isl)

    # 可用链路的距离应在合理范围
    available_dists = [r.distance_km for r in isl if r.available]
    @test all(d -> 0.0 < d <= LEO_DEFAULTS.isl_max_range_km, available_dists)

    # 5. 基于可用 ISL 构建邻接矩阵并计算全对最短路
    weights = Float64[r.latency_ms for r in isl if r.available]
    available_links = Tuple{Int,Int}[
        (Int(links[i][1]), Int(links[i][2]))
        for (i, r) in enumerate(isl) if r.available
    ]
    adj = build_adjacency(T, available_links, weights)
    D = all_pairs_shortest_paths(adj)
    @test size(D) == (T, T)
    @test D[1, 1] == 0.0
    @test count(isfinite, D) > T  # 至少存在跨卫星可达路径

    # 6. 北京地面站 GSL 可见性
    gsl_avail, gsl_dist, gsl_elev, _ = evaluate_gsl_batch(
        last_pos, [(39.9042, 116.4074, 0.0)]; constraints=LEO_DEFAULTS)
    @test size(gsl_avail) == (T, 1)
    nvis = sum(gsl_avail)
    @test 0 <= nvis <= T
    # 若存在可见卫星，仰角应为正、距离小于最大 GSL 距离
    for i in 1:T
        if gsl_avail[i, 1]
            @test gsl_elev[i, 1] > 0.0
            @test gsl_dist[i, 1] <= LEO_DEFAULTS.gsl_max_range_km
        end
    end
end

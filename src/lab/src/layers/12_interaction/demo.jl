# ===== 一键演示入口 =====
# 新用户（或 AI）一行代码跑通完整仿真
# 用法：julia --project=. -e 'using SatelliteSimJulia; demo()'

using Printf

export demo, run_examples

"""
    demo()

一键演示：从零跑通一个完整的 LEO 星座网络仿真。

```julia
using SatelliteSimJulia
demo()
```
"""
function demo()
    println("""
    ╔══════════════════════════════════════════════════╗
    ║         SatelliteSimJulia 一键演示               ║
    ║    LEO 卫星星座仿真 + 网络 + 可微优化 + AI        ║
    ╚══════════════════════════════════════════════════╝
    """)

    t0 = time()

    # ── 步骤 1：生成 Iridium 星座 ──
    println("【步骤 1】生成 Iridium 66/6 星座（780km, 86.4°）")
    elems = generate_walker_delta(T=66, P=6, F=2, alt_km=780.0, inc_deg=86.4)
    @printf("  ✓ 生成 %d 颗卫星\n", length(elems))

    # ── 步骤 2：轨道传播 ──
    println("\n【步骤 2】轨道传播（二体，2 步）")
    pos = propagate_to_ecef(elems, [0.0, 60.0])
    @printf("  ✓ 位置矩阵: %s (卫星×时间×坐标)\n", size(pos))
    r = sqrt(sum(abs2, pos[1,1,:]))
    @printf("  ✓ 卫星1半径: %.1f km (期望 ≈7158 = 6378+780)\n", r)

    # ── 步骤 3：ISL 链路评估 ──
    println("\n【步骤 3】ISL 物理评估（+Grid 拓扑）")
    topo = generate_topology(GridPlusStrategy(), 66, 6)
    links = vcat(topo.static_links, topo.dynamic_candidates)
    isl = evaluate_isl_batch(positions_at_last(pos), links; constraints=LEO_DEFAULTS)
    n_isl = count(r.available for r in isl)
    @printf("  ✓ 拓扑链路: %d, 可用 ISL: %d (%.1f%%)\n",
        length(links), n_isl, n_isl/length(links)*100)

    # ── 步骤 4：路由 ──
    println("\n【步骤 4】最短路径路由")
    avail = [(Int(links[i][1]), Int(links[i][2])) for (i,r) in enumerate(isl) if r.available]
    weights = Float64[r.latency_ms for r in isl if r.available]
    D = all_pairs_shortest_paths(build_adjacency(66, avail, weights))
    lat = compute_latency(D)
    net = compute_network_metrics(D)
    @printf("  ✓ avg 时延: %.1f ms, max: %.1f ms\n", lat.avg_latency_ms, lat.max_latency_ms)
    @printf("  ✓ 连通率: %.1f%%, 网络直径: %.1f ms\n", net.connectivity_ratio*100, net.diameter)

    # ── 步骤 5：覆盖率（北京 + 新加坡）──
    println("\n【步骤 5】GSL 覆盖评估")
    cities = [
        ("北京", 39.9042, 116.4074),
        ("新加坡", 1.3521, 103.8198),
    ]
    for (name, lat_c, lon_c) in cities
        av, dist, elev, delay = evaluate_gsl_batch(positions_at_last(pos), [(lat_c, lon_c, 0.0)])
        n_vis = sum(av)
        if n_vis > 0
            max_el = maximum(elev[av])
            @printf("  ✓ %s: %d 颗可见, 最高仰角 %.1f°\n", name, n_vis, max_el)
        else
            @printf("  · %s: 无可见卫星\n", name)
        end
    end

    # ── 步骤 6：可微优化展示 ──
    println("\n【步骤 6】多传播器对比展示")
    pos_j2 = propagate_positions(elems, [0.0, 60.0]; propagator=J2Propagator())
    drift = sqrt(sum(abs2, positions_at_last(pos) .- positions_at_last(pos_j2)))
    @printf("  ✓ TwoBody vs J2 位置差: %.2f km\n", drift)
    @printf("  ✓ 可用传播器: TwoBody / J2 / J4 / SGP4 / HPOP\n")

    # ── 步骤 7：AI 工具展示 ──
    println("\n【步骤 7】AI 适配展示")
    schemas = build_tool_schemas()
    @printf("  ✓ AI 工具数: %d (run_simulation/scan_parameter/compare/list)\n", length(schemas))
    println("  ✓ 启动 AI 助手: agent_repl(LLMProvider())")

    elapsed = time() - t0
    println("""
    ════════════════════════════════════════════════════
      演示完成！耗时 $(round(elapsed, digits=2))s

      下一步：
        • run_examples()  — 跑 3 个预编排实验
        • agent_repl(LLMProvider())  — AI 对话仿真
        • voice_agent_repl(LLMProvider())  — 语音友好对话
        • optimize_coverage(loss, x0)  — 可微优化

      文档：docs/PLATFORM_STATUS_REPORT.md
    ════════════════════════════════════════════════════
    """)
end

"""
    run_examples()

跑 3 个预编排工具示例：覆盖评估 + 路由评估 + 全套评估。
"""
function run_examples()
    println("=" ^ 50)
    println("预编排工具示例")
    println("=" ^ 50)

    # 示例 1：覆盖评估
    println("\n【示例 1】assess_coverage — 快速覆盖检查")
    elems = generate_walker_delta(T=66, P=6, F=2, alt_km=780.0, inc_deg=86.4)
    pos = propagate_to_ecef(elems, [0.0, 60.0])
    users = [GroundUser("test", 39.9, 116.4, 0.0, 100.0, "demo")]
    gsl, cov = assess_coverage(pos, users, LEO_DEFAULTS)
    @printf("  覆盖率: %.1f%%, 可见卫星: %d\n", cov.coverage_ratio*100, sum(gsl))

    # 示例 2：路由评估
    println("\n【示例 2】assess_routing — 快速路由检查")
    D, avail, isl = assess_routing(pos, 66, 6, GridPlusStrategy(), LEO_DEFAULTS)
    lat = compute_latency(D)
    @printf("  可用 ISL: %d, avg 时延: %.1f ms\n", length(avail), lat.avg_latency_ms)

    # 示例 3：全套评估
    println("\n【示例 3】full_constellation_assessment — 完整评估")
    config = ExperimentConfig(;
        name="demo_full",
        constellation_params=Dict(:T=>66.0, :P=>6.0, :F=>2.0, :alt_km=>780.0, :inc_deg=>86.4),
        tspan=[0.0, 60.0],
    )
    result = run_experiment(config)
    @printf("  覆盖: %.1f%%, 时延: %.1fms, 连通: %.1f%%, fitness: %.3f\n",
        result.coverage.coverage_ratio*100,
        result.latency.avg_latency_ms,
        result.network.connectivity_ratio*100,
        result.fitness)

    println("\n" * "=" ^ 50)
    println("示例完成！")
end

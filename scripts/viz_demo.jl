#!/usr/bin/env julia
#
# viz_demo.jl — 一键出图演示
#
# 用法：julia --project=. scripts/viz_demo.jl
#
# 产出：
#   outputs/viz/iridium_3d.png          — 3D 轨道快照（地球+卫星+ISL）
#   outputs/viz/iridium_3d_route.png    — 3D 快照（含路由路径高亮）
#   outputs/viz/iridium_ground_track.png — 2D 地面轨迹

using Printf

# ── 确保输出目录 ──
output_dir = joinpath(@__DIR__, "..", "outputs", "viz")
mkpath(output_dir)

println("""
╔══════════════════════════════════════════════════╗
║       SatelliteSimJulia 可视化演示                ║
╚══════════════════════════════════════════════════╝
""")

using SatelliteSimJulia
using CairoMakie

# ════════════════════════════════════════════════════
# 1. 生成 Iridium 66/6 星座
# ════════════════════════════════════════════════════
println("【步骤 1】生成 Iridium 66/6 星座（780km, 86.4°）")
elems = generate_walker_delta(T = 66, P = 6, F = 2, alt_km = 780.0, inc_deg = 86.4)
@printf("  ✓ 生成 %d 颗卫星\n", length(elems))

# ════════════════════════════════════════════════════
# 2. 轨道传播（1 小时，1 分钟步长）
# ════════════════════════════════════════════════════
println("\n【步骤 2】轨道传播（TwoBody, 60 分钟, 1 分钟步长）")
tspan = collect(0.0:60.0:3600.0)
pos = propagate_to_ecef(elems, tspan)
@printf("  ✓ 位置矩阵: %s (卫星×时间×坐标)\n", size(pos))

# ════════════════════════════════════════════════════
# 3. ISL 链路评估
# ════════════════════════════════════════════════════
println("\n【步骤 3】ISL 物理评估（+Grid 拓扑）")
topo = generate_topology(GridPlusStrategy(), 66, 6)
links = vcat(topo.static_links, topo.dynamic_candidates)
isl = evaluate_isl_batch(positions_at_last(pos), links; constraints = LEO_DEFAULTS)
n_isl = count(r.available for r in isl)
@printf("  ✓ 拓扑链路: %d, 可用 ISL: %d (%.1f%%)\n",
    length(links), n_isl, n_isl / length(links) * 100)

isl_pairs = [(Int(links[i][1]), Int(links[i][2])) for i in eachindex(links)]
isl_available = [r.available for r in isl]

# ════════════════════════════════════════════════════
# 4. 路由（用于路径高亮演示）
# ════════════════════════════════════════════════════
println("\n【步骤 4】最短路径路由")
avail = [(Int(links[i][1]), Int(links[i][2])) for (i, r) in enumerate(isl) if r.available]
weights = Float64[r.latency_ms for r in isl if r.available]
D = all_pairs_shortest_paths(build_adjacency(66, avail, weights))
lat = compute_latency(D)
@printf("  ✓ avg 时延: %.1f ms, max: %.1f ms\n", lat.avg_latency_ms, lat.max_latency_ms)

# 选一条有代表性的路由路径（卫星 1 → 对跖点）
route_dst = mod1(1 + div(66, 2), 66)
route_path = let
    _cur = 1
    _visited = Set([1])
    _path = Int[]
    for _ in 1:66
        _cur == route_dst && break
        _best = 0
        _bcost = Inf
        for nb in 1:66
            nb == _cur && continue
            nb in _visited && continue
            !isfinite(D[nb, route_dst]) && continue
            _c = D[_cur, nb] + D[nb, route_dst]
            _c < _bcost && (_bcost = _c; _best = nb)
        end
        _best == 0 && break
        push!(_path, _best)
        push!(_visited, _best)
        _cur = _best
    end
    pushfirst!(_path, 1)
    _path
end
@printf("  ✓ 演示路由: 卫星 %d → 卫星 %d (%d 跳)\n", 1, route_dst, length(route_path) - 1)

# ════════════════════════════════════════════════════
# 5. 3D 轨道快照（地球 + 卫星 + ISL）
# ════════════════════════════════════════════════════
println("\n【步骤 5】绘制 3D 轨道快照（地球 + 卫星 + ISL）")
fig1 = plot_orbit_snapshot(
    pos;
    isl_pairs = isl_pairs,
    isl_available = isl_available,
    config = MakieViewerConfig(;
        title = "Iridium 66/6 Constellation (780km, 86.4°)",
        time_index = 1,
        show_orbits = true,
        show_isl = true,
        show_ground_stations = false,
        satellite_markersize = 4.0,
    ),
)
path1 = joinpath(output_dir, "iridium_3d.png")
save(path1, fig1)
@printf("  ✓ 保存: %s\n", path1)

# ════════════════════════════════════════════════════
# 5b. 3D 轨道快照（带波束足迹）
# ════════════════════════════════════════════════════
println("\n【步骤 5b】绘制 3D 快照（带波束足迹）")
fig1b = plot_orbit_snapshot(
    pos;
    isl_pairs = isl_pairs,
    isl_available = isl_available,
    config = MakieViewerConfig(;
        title = "Iridium 66/6 — Beam Footprints (30°)",
        time_index = 1,
        show_orbits = true,
        show_isl = true,
        show_ground_stations = false,
        show_beams = true,
        beam_angle_deg = 30.0,
        satellite_markersize = 4.0,
    ),
)
path1b = joinpath(output_dir, "iridium_3d_beams.png")
save(path1b, fig1b)
@printf("  ✓ 保存: %s\n", path1b)

# ════════════════════════════════════════════════════
# 6. 3D 轨道快照（含路由路径高亮）
# ════════════════════════════════════════════════════
println("\n【步骤 6】绘制 3D 快照（含路由路径高亮）")
fig2 = plot_orbit_snapshot(
    pos;
    isl_pairs = isl_pairs,
    isl_available = isl_available,
    route_path = route_path,
    config = MakieViewerConfig(;
        title = "Iridium 66/6 — Route: Sat $(route_path[1]) → Sat $(route_path[end])",
        time_index = 1,
        show_orbits = false,
        show_isl = true,
        show_route = true,
        satellite_markersize = 4.0,
    ),
)
path2 = joinpath(output_dir, "iridium_3d_route.png")
save(path2, fig2)
@printf("  ✓ 保存: %s\n", path2)

# ════════════════════════════════════════════════════
# 7. 2D 地面轨迹
# ════════════════════════════════════════════════════
println("\n【步骤 7】绘制 2D 地面轨迹")
fig3 = plot_ground_track(
    pos;
    title = "Iridium 66/6 Ground Track (1 hour)",
)
path3 = joinpath(output_dir, "iridium_ground_track.png")
save(path3, fig3)
@printf("  ✓ 保存: %s\n", path3)

# ════════════════════════════════════════════════════
# 8. 时间动画（MP4）
# ════════════════════════════════════════════════════
println("\n【步骤 8】生成时间动画 MP4（60 帧，10 fps）")
anim_path = animate_orbit(
    pos;
    isl_pairs = isl_pairs,
    isl_available = isl_available,
    route_path = route_path,
    output_path = joinpath(output_dir, "iridium_anim.mp4"),
    fps = 10,
    config = MakieViewerConfig(;
        title = "Iridium 66/6 — Orbit Animation",
        show_orbits = false,
        show_isl = true,
        show_route = true,
        show_ground_stations = false,
        satellite_markersize = 4.0,
    ),
)
@printf("  ✓ 保存: %s\n", anim_path)

# ════════════════════════════════════════════════════
# 9. 覆盖热力图
# ════════════════════════════════════════════════════
println("\n【步骤 9】绘制覆盖热力图")
fig4 = plot_coverage_heatmap(
    pos;
    time_index = 0,
    grid_nlat = 90,
    grid_nlon = 180,
    min_elev_deg = 10.0,
    title = "Iridium 66/6 Coverage Heatmap (1 hour aggregate)",
    show_ground_track = true,
)
path4 = joinpath(output_dir, "iridium_coverage.png")
save(path4, fig4)
@printf("  ✓ 保存: %s\n", path4)

# ════════════════════════════════════════════════════
# 10. 多面板 Dashboard
# ════════════════════════════════════════════════════
println("\n【步骤 10】绘制多面板 Dashboard")
fig5 = plot_dashboard(
    pos;
    time_index = 1,
    isl_pairs = isl_pairs,
    isl_available = isl_available,
    route_path = route_path,
    config = MakieViewerConfig(;
        title = "Iridium 66/6 Dashboard",
        show_orbits = true,
        show_isl = true,
        show_route = true,
        show_ground_stations = false,
        satellite_markersize = 3.0,
        orbit_linewidth = 0.8,
        isl_linewidth = 0.6,
        route_linewidth = 2.5,
        dark_theme = true,
    ),
    grid_nlat = 60,
    grid_nlon = 120,
    min_elev_deg = 10.0,
    title = "Iridium 66/6 Multi-Panel Dashboard",
)
path5 = joinpath(output_dir, "iridium_dashboard.png")
save(path5, fig5)
@printf("  ✓ 保存: %s\n", path5)

println("""
════════════════════════════════════════════════════
  可视化演示完成！

  产出图片：
    • $(path1)
    • $(path1b)
    • $(path2)
    • $(path3)
    • $(path4)
    • $(path5)

  产出动画：
    • $(anim_path)

  交互模式（需要 GLMakie）：
    using GLMakie; GLMakie.activate!()
    fig = plot_orbit_snapshot(pos; show_isl=true)
════════════════════════════════════════════════════
""")

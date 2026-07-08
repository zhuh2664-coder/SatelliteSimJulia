# ===== 公开 API =====
#
# 统一的可视化入口函数。
# 核心 API 接受 Array{Float64,3}（demo 流程直接可用），
# 兼容 API 接受 ConstellationEphemeris（旧代码路径）。

export plot_orbit_snapshot, plot_makie_viewer, show_makie_viewer,
       save_orbit_snapshot, show_earth_viewer, show_orbit_viewer

# ────────────────────────────────────────────────────────────
# 核心 API：plot_orbit_snapshot（Array{Float64,3}）
# ────────────────────────────────────────────────────────────

"""
    plot_orbit_snapshot(positions; kwargs...) -> Figure

3D 轨道快照：地球 + 卫星 + ISL 链路 + 地面站 + 路由路径。

# 参数
- `positions::Array{Float64,3}` — N×T×3 ECEF (km)
- `ground_stations::Vector{GroundStation}` — 地面站（可选）
- `ground_xyz::Matrix{Float64}` — 预计算的地面站 G×3 xyz（可选，优先于 ground_stations）
- `isl_pairs::Vector{Tuple{Int,Int}}` — ISL 边列表
- `isl_available::Vector{Bool}` — ISL 可用掩码
- `gsl_mask::Matrix{Bool}` — GSL 可见掩码 (N_sat × N_ground)
- `route_path::Vector{Int}` — 路由路径（卫星 ID 序列）
- `config::MakieViewerConfig` — 可视化配置
"""
function plot_orbit_snapshot(positions::Array{Float64,3};
    ground_stations::AbstractVector{GroundStation} = GroundStation[],
    ground_xyz = nothing,
    isl_pairs::AbstractVector{<:Tuple} = Tuple{Int,Int}[],
    isl_available::AbstractVector{Bool} = Bool[],
    gsl_mask::Matrix{Bool} = Matrix{Bool}(undef, 0, 0),
    route_path::AbstractVector{Int} = Int[],
    config::MakieViewerConfig = MakieViewerConfig(),
)
    time_index = config.time_index
    n_time = size(positions, 2)
    time_index = clamp(time_index, 1, n_time)

    # 当前时刻卫星位置 (N×3)
    pos_now = @view positions[:, time_index, :]

    figure = Figure(size = (960, 720))
    axis = Axis3(
        figure[1, 1],
        title = config.title,
        aspect = :data,
        # :fit 让立方体填满单元格（默认 :fitzoom 会为旋转留白，导致画面偏小）
        viewmode = :fit,
        xlabel = "ECEF x (km)",
        ylabel = "ECEF y (km)",
        zlabel = "ECEF z (km)",
    )

    # 1. 地球
    draw_earth!(axis;
        show_coastlines = true,
        show_grid = false,
    )

    # 2. 轨迹线
    if config.show_orbits && n_time > 1
        draw_orbit_trails!(axis, positions;
            linewidth = config.orbit_linewidth,
            color = (:gray30, 0.3),
        )
    end

    # 3. ISL 链路
    if config.show_isl && !isempty(isl_pairs)
        draw_isl_links!(axis, pos_now, isl_pairs, isl_available;
            linewidth = config.isl_linewidth,
        )
    end

    # 4. 地面站
    gs_xyz = ground_xyz !== nothing ? ground_xyz :
              isempty(ground_stations) ? zeros(Float64, 0, 3) :
              ground_stations_to_xyz(ground_stations)

    if config.show_ground_stations && size(gs_xyz, 1) > 0
        draw_satellites!(axis, gs_xyz;
            markersize = config.ground_markersize,
            color = :dodgerblue,
            label = "Ground Station",
        )
    end

    # 5. GSL 连线
    if config.show_gsl && !isempty(gsl_mask) && size(gs_xyz, 1) > 0
        draw_gsl_links!(axis, pos_now, gs_xyz, gsl_mask)
    end

    # 6. 路由路径高亮
    if config.show_route && !isempty(route_path)
        draw_route_path!(axis, pos_now, route_path;
            linewidth = config.route_linewidth,
        )
    end

    # 7. 卫星散点（最后画，在最上层）
    draw_satellites!(axis, pos_now;
        markersize = config.satellite_markersize,
        color = :orange,
        label = "Satellite",
    )

    # 图例：叠加在坐标轴单元格内（tellwidth/tellheight=false），
    # 避免与 Axis3 争抢同一 grid cell 的空间而把立方体挤小。
    if config.show_isl || config.show_route || config.show_ground_stations
        Legend(figure[1, 1], axis;
            tellwidth = false,
            tellheight = false,
            halign = :right,
            valign = :top,
            margin = (8, 8, 8, 8),
            framevisible = true,
            backgroundcolor = (:white, 0.7),
        )
    end

    return figure
end

# ────────────────────────────────────────────────────────────
# 兼容 API：ConstellationEphemeris
# ────────────────────────────────────────────────────────────

"""
    plot_orbit_snapshot(ephemeris::ConstellationEphemeris; ground_stations, config)

兼容旧 API：从 ConstellationEphemeris 提取位置矩阵后绘制。
"""
function plot_orbit_snapshot(ephemeris::ConstellationEphemeris;
    ground_stations::AbstractVector{GroundStation} = GroundStation[],
    config::MakieViewerConfig = MakieViewerConfig(),
)
    positions = ephemeris_to_positions(ephemeris)
    return plot_orbit_snapshot(positions;
        ground_stations = ground_stations,
        config = config,
    )
end

# ────────────────────────────────────────────────────────────
# 别名和便捷函数
# ────────────────────────────────────────────────────────────

"""plot_makie_viewer 是 plot_orbit_snapshot 的别名。"""
plot_makie_viewer(args...; kwargs...) = plot_orbit_snapshot(args...; kwargs...)

"""show_makie_viewer 同 plot_makie_viewer（保留向后兼容）。"""
show_makie_viewer(args...; kwargs...) = plot_orbit_snapshot(args...; kwargs...)

"""show_orbit_viewer 同 plot_orbit_snapshot（保留向后兼容）。"""
show_orbit_viewer(args...; kwargs...) = plot_orbit_snapshot(args...; kwargs...)

# ────────────────────────────────────────────────────────────
# 保存快照
# ────────────────────────────────────────────────────────────

"""
    save_orbit_snapshot(path, positions; kwargs...)

绘制 3D 轨道快照并保存到文件。返回文件路径。
"""
function save_orbit_snapshot(path::AbstractString, positions::Array{Float64,3};
    kwargs...,
)
    figure = plot_orbit_snapshot(positions; kwargs...)
    save(path, figure)
    return path
end

"""兼容旧 API。"""
function save_orbit_snapshot(path::AbstractString, ephemeris::ConstellationEphemeris;
    ground_stations::AbstractVector{GroundStation} = GroundStation[],
    config::MakieViewerConfig = MakieViewerConfig(),
)
    positions = ephemeris_to_positions(ephemeris)
    return save_orbit_snapshot(path, positions;
        ground_stations = ground_stations,
        config = config,
    )
end

# ────────────────────────────────────────────────────────────
# 独立地球视图
# ────────────────────────────────────────────────────────────

"""
    show_earth_viewer(; config) -> Figure

独立地球渲染（无卫星）。
"""
function show_earth_viewer(; config::EarthViewerConfig = EarthViewerConfig())
    figure = Figure(size = (760, 680))
    axis = Axis3(
        figure[1, 1],
        title = config.title,
        aspect = :data,
        xlabel = "x (km)",
        ylabel = "y (km)",
        zlabel = "z (km)",
    )

    draw_earth!(axis;
        show_coastlines = config.show_coastlines,
        show_grid = config.show_grid,
    )

    return figure
end

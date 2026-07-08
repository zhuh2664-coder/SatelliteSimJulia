# ===== 多面板 Dashboard =====
#
# 把 3D 轨道视图、2D 地面轨迹、覆盖热力图集成到单一 Figure。
# 输入仍是裸数组 Array{Float64,3}，不依赖 ConstellationEphemeris。

export plot_dashboard

"""
    plot_dashboard(positions::Array{Float64,3}; kwargs...) -> Figure

多面板仪表板：
- 左侧：3D 轨道 + 卫星 + ISL + 路由 + 波束
- 右上：2D 地面轨迹
- 右下：覆盖热力图

# 参数
- `positions::Array{Float64,3}` — N×T×3 ECEF (km)
- `time_index::Int` — 3D 快照使用的时间步
- `isl_pairs`, `isl_available`, `gsl_mask`, `route_path` — 同 plot_orbit_snapshot
- `ground_stations`, `ground_xyz` — 同 plot_orbit_snapshot
- `config::MakieViewerConfig` — 3D 视图配置
- `grid_nlat::Int`, `grid_nlon::Int` — 覆盖网格密度
- `min_elev_deg::Real` — 覆盖热力图最小仰角
- `title::String` — dashboard 总标题
"""
function plot_dashboard(positions::Array{Float64,3};
    time_index::Int = 1,
    ground_stations::AbstractVector{GroundStation} = GroundStation[],
    ground_xyz = nothing,
    isl_pairs::AbstractVector{<:Tuple} = Tuple{Int,Int}[],
    isl_available::AbstractVector{Bool} = Bool[],
    gsl_mask::Matrix{Bool} = Matrix{Bool}(undef, 0, 0),
    route_path::AbstractVector{Int} = Int[],
    config::MakieViewerConfig = MakieViewerConfig(),
    grid_nlat::Int = 60,
    grid_nlon::Int = 120,
    min_elev_deg::Real = 10.0,
    title::AbstractString = "Constellation Dashboard",
)
    n_time = size(positions, 2)
    t = clamp(time_index, 1, n_time)
    pos_now = positions[:, t, :]

    figure = Figure(size = (1400, 800))

    if config.dark_theme
        figure.scene.backgroundcolor[] = RGBf(0.0, 0.0, 0.05)
    end

    # 总标题
    Label(figure[0, 1:2], title;
        fontsize = 20,
        color = config.dark_theme ? :white : :black,
        tellwidth = false,
    )

    # ── 左：3D 轨道视图 ──
    axis3 = Axis3(
        figure[1:2, 1],
        title = "3D Orbit View",
        aspect = :data,
        xlabel = "x (km)",
        ylabel = "y (km)",
        zlabel = "z (km)",
    )
    if config.dark_theme
        axis3.backgroundcolor = RGBf(0.0, 0.0, 0.05)
        axis3.titlecolor = :white
        axis3.xlabelcolor = :white
        axis3.ylabelcolor = :white
        axis3.zlabelcolor = :white
        axis3.xticklabelcolor = :white
        axis3.yticklabelcolor = :white
        axis3.zticklabelcolor = :white
    end

    draw_earth!(axis3;
        show_coastlines = true,
        show_grid = false,
        dark_theme = config.dark_theme,
    )

    if config.show_orbits && n_time > 1
        draw_orbit_trails!(axis3, positions;
            linewidth = config.orbit_linewidth,
            color = (:gray30, 0.3),
        )
    end

    if config.show_isl && !isempty(isl_pairs)
        draw_isl_links!(axis3, pos_now, isl_pairs, isl_available;
            linewidth = config.isl_linewidth,
        )
    end

    gs_xyz = ground_xyz !== nothing ? ground_xyz :
              isempty(ground_stations) ? zeros(Float64, 0, 3) :
              ground_stations_to_xyz(ground_stations)

    if config.show_ground_stations && size(gs_xyz, 1) > 0
        draw_satellites!(axis3, gs_xyz;
            markersize = config.ground_markersize,
            color = :dodgerblue,
            label = "Ground Station",
        )
    end

    if config.show_gsl && !isempty(gsl_mask) && size(gs_xyz, 1) > 0
        draw_gsl_links!(axis3, pos_now, gs_xyz, gsl_mask)
    end

    if config.show_route && !isempty(route_path)
        draw_route_path!(axis3, pos_now, route_path;
            linewidth = config.route_linewidth,
        )
    end

    if config.show_beams
        draw_beam_footprints!(axis3, pos_now;
            beam_angle_deg = config.beam_angle_deg,
            color = config.dark_theme ? (:cyan, 0.35) : (:cyan, 0.5),
        )
    end

    draw_satellites!(axis3, pos_now;
        markersize = config.satellite_markersize,
        color = :orange,
        label = "Satellite",
    )

    # ── 右上：地面轨迹 ──
    ax_track = GeoAxis(
        figure[1, 2],
        title = "Ground Track",
        dest = "+proj=eqearth",
        limits = ((-180, 180), (-90, 90)),
    )
    _draw_ground_track_on_axis!(ax_track, positions)

    # ── 右下：覆盖热力图 ──
    ax_cov = GeoAxis(
        figure[2, 2],
        title = "Coverage Heatmap",
        dest = "+proj=eqearth",
        limits = ((-180, 180), (-90, 90)),
    )
    _draw_coverage_heatmap_on_axis!(ax_cov, positions;
        grid_nlat = grid_nlat,
        grid_nlon = grid_nlon,
        min_elev_deg = min_elev_deg,
    )

    return figure
end

# ────────────────────────────────────────────────────────────
# dashboard 专用内部辅助：在已有 GeoAxis 上画地面轨迹
# ────────────────────────────────────────────────────────────

function _draw_ground_track_on_axis!(axis, positions::Array{Float64,3})
    coast = try
        GeoMakie.coastlines(110)
    catch
        nothing
    end
    if coast !== nothing
        lines!(axis, coast; color = :black, linewidth = 0.5)
    end

    n_sat = size(positions, 1)
    n_time = size(positions, 2)
    for i in 1:n_sat
        lons = Float64[]
        lats = Float64[]
        for t in 1:n_time
            lat, lon, _ = ecef_to_latlon(
                positions[i, t, 1], positions[i, t, 2], positions[i, t, 3])
            push!(lons, lon)
            push!(lats, lat)
        end
        lines!(axis, lons, lats;
            color = (:steelblue, 0.4),
            linewidth = 0.8,
        )
        scatter!(axis, lons, lats;
            markersize = 2,
            color = :steelblue,
        )
    end
    return nothing
end

# ────────────────────────────────────────────────────────────
# dashboard 专用内部辅助：在已有 GeoAxis 上画覆盖热力图
# ────────────────────────────────────────────────────────────

function _draw_coverage_heatmap_on_axis!(axis, positions::Array{Float64,3};
    grid_nlat::Int = 60,
    grid_nlon::Int = 120,
    min_elev_deg::Real = 10.0,
)
    lat_centers = range(-90.0, 90.0; length = grid_nlat)
    lon_centers = range(-180.0, 180.0; length = grid_nlon)
    lat_edges = range(-90.0, 90.0; length = grid_nlat + 1)
    lon_edges = range(-180.0, 180.0; length = grid_nlon + 1)

    grid = compute_coverage_grid(positions, collect(lat_centers), collect(lon_centers);
        time_index = 1, min_elev_deg = min_elev_deg)

    hm = heatmap!(axis, collect(lon_edges), collect(lat_edges), grid';
        colormap = :plasma,
        colorrange = (0, max(1, maximum(grid))),
    )

    coast = try
        GeoMakie.coastlines(110)
    catch
        nothing
    end
    if coast !== nothing
        lines!(axis, coast; color = :black, linewidth = 0.5)
    end

    return hm
end

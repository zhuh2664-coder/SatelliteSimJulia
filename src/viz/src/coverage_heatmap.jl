# ===== 覆盖热力图 =====
#
# 2D 地图上的卫星覆盖次数聚合。
# 输入 Array{Float64,3}（N×T×3 ECEF km），输出 GeoMakie 热力图。

export plot_coverage_heatmap

"""
    elevation_deg(sat_ecef::NTuple{3,Real}, gs_ecef::NTuple{3,Real})

计算卫星相对地面某点的仰角（度）。
"""
function _elevation_deg(sat_ecef::NTuple{3,Real}, gs_ecef::NTuple{3,Real})
    # 地面站本地天顶方向 = 从地心指向地面站（单位化）
    r_gs = sqrt(gs_ecef[1]^2 + gs_ecef[2]^2 + gs_ecef[3]^2)
    r_gs < 1e-9 && return -90.0
    zenith = (gs_ecef[1] / r_gs, gs_ecef[2] / r_gs, gs_ecef[3] / r_gs)

    # 卫星相对地面站的位置向量
    dx = sat_ecef[1] - gs_ecef[1]
    dy = sat_ecef[2] - gs_ecef[2]
    dz = sat_ecef[3] - gs_ecef[3]
    d = sqrt(dx^2 + dy^2 + dz^2)
    d < 1e-9 && return -90.0

    # 仰角 = 90° - 卫星与天顶夹角
    cos_z = (dx * zenith[1] + dy * zenith[2] + dz * zenith[3]) / d
    # clamp 处理数值误差
    cos_z = clamp(cos_z, -1.0, 1.0)
    elev = asin(cos_z)  # rad
    return rad2deg(elev)
end

"""
    compute_coverage_grid(positions, lats, lons; time_index, min_elev_deg) -> Matrix{Int}

计算给定 lat/lon 网格上每个点被多少颗卫星覆盖（满足最小仰角）。
返回 (n_lat × n_lon) 整数矩阵。
"""
function compute_coverage_grid(
    positions::Array{Float64,3},
    lat_centers::AbstractVector{<:Real},
    lon_centers::AbstractVector{<:Real};
    time_index::Int = 1,
    min_elev_deg::Real = 10.0,
)
    n_sat = size(positions, 1)
    n_lat = length(lat_centers)
    n_lon = length(lon_centers)
    grid = zeros(Int, n_lat, n_lon)

    for (li, lat) in enumerate(lat_centers)
        for (lj, lon) in enumerate(lon_centers)
            gx, gy, gz = latlon_to_xyz(lat, lon)
            count = 0
            for s in 1:n_sat
                sx = positions[s, time_index, 1]
                sy = positions[s, time_index, 2]
                sz = positions[s, time_index, 3]
                elev = _elevation_deg((sx, sy, sz), (gx, gy, gz))
                if elev >= min_elev_deg
                    count += 1
                end
            end
            grid[li, lj] = count
        end
    end
    return grid
end

"""
    compute_temporal_coverage_grid(positions, lat_centers, lon_centers; min_elev_deg) -> Matrix{Int}

计算所有时间步的覆盖累计：每个格网点被任意卫星覆盖的时间步数。
"""
function compute_temporal_coverage_grid(
    positions::Array{Float64,3},
    lat_centers::AbstractVector{<:Real},
    lon_centers::AbstractVector{<:Real};
    min_elev_deg::Real = 10.0,
)
    n_time = size(positions, 2)
    grid = zeros(Int, length(lat_centers), length(lon_centers))
    for t in 1:n_time
        grid .+= compute_coverage_grid(positions, lat_centers, lon_centers;
            time_index = t, min_elev_deg = min_elev_deg)
    end
    return grid
end

"""
    plot_coverage_heatmap(positions::Array{Float64,3}; kwargs...) -> Figure

绘制卫星覆盖热力图（2D 地图）。

# 参数
- `positions::Array{Float64,3}` — N×T×3 ECEF (km)
- `time_index::Int` — 使用哪个时间步（默认 1；若为 0 则聚合所有时间步）
- `grid_nlat::Int`, `grid_nlon::Int` — 网格密度
- `min_elev_deg::Real` — 最小仰角阈值
- `title::String` — 标题
- `colormap` — Makie colormap
- `show_ground_track::Bool` — 是否叠加卫星地面轨迹
"""
function plot_coverage_heatmap(positions::Array{Float64,3};
    time_index::Int = 1,
    grid_nlat::Int = 90,
    grid_nlon::Int = 180,
    min_elev_deg::Real = 10.0,
    title::AbstractString = "Satellite Coverage",
    colormap = :plasma,
    show_ground_track::Bool = true,
)
    n_time = size(positions, 2)

    # Makie heatmap 在 GeoAxis/CairoMakie 下需要 edges：x 长度 = n_lon+1, y 长度 = n_lat+1
    # grid 用中心点计算，维度 n_lat × n_lon
    lat_centers = range(-90.0, 90.0; length = grid_nlat)
    lon_centers = range(-180.0, 180.0; length = grid_nlon)
    lat_edges = range(-90.0, 90.0; length = grid_nlat + 1)
    lon_edges = range(-180.0, 180.0; length = grid_nlon + 1)

    if time_index == 0
        grid = compute_temporal_coverage_grid(positions, collect(lat_centers), collect(lon_centers);
            min_elev_deg = min_elev_deg)
        title = title * " (temporal aggregate)"
    else
        t = clamp(time_index, 1, n_time)
        grid = compute_coverage_grid(positions, collect(lat_centers), collect(lon_centers);
            time_index = t, min_elev_deg = min_elev_deg)
    end

    figure = Figure(size = (1000, 520))
    axis = GeoAxis(
        figure[1, 1],
        title = title,
        dest = "+proj=eqearth",
        limits = ((-180, 180), (-90, 90)),
    )

    # 热力图：edges 坐标，grid 在 GeoAxis/CairoMakie 下需要维度 (n_lon, n_lat)
    hm = heatmap!(axis, collect(lon_edges), collect(lat_edges), grid';
        colormap = colormap,
        colorrange = (0, max(1, maximum(grid))),
    )

    # 海岸线
    coast = try
        GeoMakie.coastlines(110)
    catch
        nothing
    end
    if coast !== nothing
        lines!(axis, coast; color = :black, linewidth = 0.5)
    end

    # 叠加地面轨迹
    if show_ground_track
        n_sat = size(positions, 1)
        for i in 1:n_sat
            lons_traj = Float64[]
            lats_traj = Float64[]
            for t in 1:n_time
                lat, lon, _ = ecef_to_latlon(
                    positions[i, t, 1], positions[i, t, 2], positions[i, t, 3])
                push!(lons_traj, lon)
                push!(lats_traj, lat)
            end
            lines!(axis, lons_traj, lats_traj;
                color = (:white, 0.3),
                linewidth = 0.6,
            )
        end
    end

    Colorbar(figure[1, 2], hm; label = "Coverage count")

    return figure
end

"""
    plot_coverage_heatmap(ephemeris::ConstellationEphemeris; kwargs...)

兼容旧 API：从 ConstellationEphemeris 提取位置后绘制。
"""
function plot_coverage_heatmap(ephemeris::ConstellationEphemeris; kwargs...)
    positions = ephemeris_to_positions(ephemeris)
    return plot_coverage_heatmap(positions; kwargs...)
end

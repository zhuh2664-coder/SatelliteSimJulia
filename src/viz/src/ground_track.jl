# ===== 2D 地面轨迹 =====
#
# 用 GeoMakie GeoAxis 等距圆柱投影绘制地面轨迹。
# 支持 Array{Float64,3} 和 ConstellationEphemeris 两种输入。

export plot_ground_track

"""
    plot_ground_track(positions::Array{Float64,3}; title, markersize)

2D 地面轨迹图（等距圆柱投影）。

# 参数
- `positions::Array{Float64,3}` — N×T×3 ECEF (km)
- `title` — 图标题
- `markersize` — 散点大小
- `trail_color` — 轨迹颜色
"""
function plot_ground_track(positions::Array{Float64,3};
    title::AbstractString = "Ground Track",
    markersize::Real = 3,
)
    n_sat = size(positions, 1)
    n_time = size(positions, 2)

    figure = Figure(size = (1000, 520))
    axis = GeoAxis(
        figure[1, 1],
        title = title,
        dest = "+proj=eqearth",
        limits = ((-180, 180), (-90, 90)),
    )

    # 绘制海岸线底图
    coast = try
        GeoMakie.coastlines(110)
    catch
        nothing
    end
    if coast !== nothing
        lines!(axis, coast; color = :black, linewidth = 0.5)
    end

    # 每颗卫星一条轨迹
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
            markersize = markersize,
            color = :steelblue,
        )
    end

    return figure
end

"""
    plot_ground_track(ephemeris::ConstellationEphemeris; title)

兼容旧 API：从 ConstellationEphemeris 提取位置后绘制。
"""
function plot_ground_track(ephemeris::ConstellationEphemeris;
    title::AbstractString = "Ground Track",
)
    positions = ephemeris_to_positions(ephemeris)
    return plot_ground_track(positions; title = title)
end

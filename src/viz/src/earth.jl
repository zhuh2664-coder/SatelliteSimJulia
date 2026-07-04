# ===== 地球渲染 =====
#
# 用 GeoMakie.coastlines() 获取 NaturalEarth 海岸线数据，
# 手动投影到 3D 球面上（lat/lon → xyz），绘制在 Axis3 上。
# 兼容 CairoMakie（无头）和 GLMakie（交互）。

export draw_earth!, latlon_to_xyz, draw_coastlines!, draw_latlon_grid!,
       draw_land_fill!, draw_atmosphere_glow!

const EARTH_R = WGS84_EQUATORIAL_RADIUS_KM

# ────────────────────────────────────────────────────────────
# 坐标转换：lat/lon/alt → ECEF xyz
# ────────────────────────────────────────────────────────────

"""地理坐标 → 3D 笛卡尔坐标（km）。`alt_km` 默认 0（地表）。"""
function latlon_to_xyz(lat_deg, lon_deg; alt_km = 0.0, radius_km = EARTH_R)
    lat = deg2rad(lat_deg)
    lon = deg2rad(lon_deg)
    r = radius_km + alt_km
    return (
        r * cos(lat) * cos(lon),
        r * cos(lat) * sin(lon),
        r * sin(lat),
    )
end

# ────────────────────────────────────────────────────────────
# 海岸线数据缓存
# ────────────────────────────────────────────────────────────

const _coastline_cache = Ref{Any}(nothing)
const _coastline_source = Ref{Symbol}(:none)  # :geo_makie | :builtin
const _land_cache = Ref{Any}(nothing)

"""加载海岸线数据（带缓存）。优先 GeoMakie，失败时 fallback 到内嵌简化数据。"""
function _load_coastlines(resolution::Int = 110)
    if _coastline_cache[] === nothing
        try
            _coastline_cache[] = GeoMakie.coastlines(resolution)
            _coastline_source[] = :geo_makie
        catch
            @warn "GeoMakie coastlines() 下载失败，使用内嵌简化海岸线数据"
            _coastline_cache[] = :builtin  # sentinel
            _coastline_source[] = :builtin
        end
    end
    return _coastline_cache[]
end

"""加载陆地多边形数据（带缓存）。"""
function _load_land(resolution::Int = 110)
    if _land_cache[] === nothing
        try
            _land_cache[] = GeoMakie.land(resolution)
        catch
            _land_cache[] = nothing
        end
    end
    return _land_cache[]
end

# ────────────────────────────────────────────────────────────
# 绘制函数
# ────────────────────────────────────────────────────────────

"""
    draw_earth!(axis; resolution, coastline_color, ocean_color, land_color, show_coastlines, dark_theme)

在 Axis3 上绘制地球球面 + 海岸线。

- `dark_theme=true`：深空黑底风格（近黑深蓝海洋 + 浅灰海岸线 + 陆地填充 + 大气辉光）
- `dark_theme=false`：原亮蓝风格（向后兼容）
- 球面 mesh 用海洋蓝色
- 海岸线用黑色线条
- 经纬网格（可选）
"""
function draw_earth!(axis;
    resolution::Int = 110,
    coastline_color = :black,
    coastline_linewidth = 0.6,
    ocean_color = RGBf(0.08, 0.25, 0.55),
    land_color = RGBf(0.22, 0.58, 0.30),
    show_coastlines = true,
    show_grid = false,
    dark_theme::Bool = false,
)
    # dark_theme 覆盖默认配色（仅当调用方未显式传入颜色时由调用方决定）
    if dark_theme
        ocean_color = RGBf(0.02, 0.05, 0.12)
        land_color = RGBf(0.10, 0.30, 0.15)
        coastline_color = (:white, 0.4)
    end

    # ── 球面 mesh ──
    n_theta = 64
    n_phi = 32
    theta = range(0, 2pi; length = n_theta)
    phi = range(0, pi; length = n_phi)
    ex = [EARTH_R * cos(t) * sin(p) for t in theta, p in phi]
    ey = [EARTH_R * sin(t) * sin(p) for t in theta, p in phi]
    ez = [EARTH_R * cos(p) for t in theta, p in phi]

    # 用 z 坐标近似着色：极地偏白/蓝，赤道深蓝
    color_field = ez ./ EARTH_R
    surface!(axis, ex, ey, ez;
        color = color_field,
        colormap = cgrad([ocean_color, dark_theme ? RGBf(0.05, 0.10, 0.20) : RGBf(0.12, 0.35, 0.65)]),
        shading = NoShading,
    )

    # ── 陆地填充（dark_theme 下让陆地轮廓可辨识）──
    if dark_theme
        draw_land_fill!(axis;
            resolution = resolution,
            color = land_color,
        )
    end

    # ── 大气辉光（dark_theme 专属：地球外侧半透明大球）──
    if dark_theme
        draw_atmosphere_glow!(axis)
    end

    # ── 海岸线 ──
    if show_coastlines
        draw_coastlines!(axis;
            resolution = resolution,
            color = coastline_color,
            linewidth = coastline_linewidth,
        )
    end

    # ── 经纬网格 ──
    if show_grid
        draw_latlon_grid!(axis; color = (:gray, 0.3), linewidth = 0.3)
    end

    return nothing
end

"""
    draw_land_fill!(axis; resolution, color)

用 GeoMakie.land() 多边形填充陆地。仅在 dark_theme 下调用。
GeoMakie.land() 不可用时静默跳过（海岸线仍画）。
"""
function draw_land_fill!(axis;
    resolution::Int = 110,
    color = RGBf(0.10, 0.30, 0.15),
)
    land = _load_land(resolution)
    land === nothing && return nothing

    for polygon in land
        pts = Point3f[]
        for p in polygon
            x, y, z = latlon_to_xyz(p[2], p[1])  # GeoMakie: p[1]=lon, p[2]=lat
            push!(pts, Point3f(x, y, z))
        end
        length(pts) < 3 && continue
        mesh!(axis, pts; color = color, shading = NoShading)
    end
    return nothing
end

"""
    draw_atmosphere_glow!(axis; ocean_color, glow_factor, alpha_max)

在地球外侧画一层半径略大的半透明球面，模拟大气辉光。
用 surface! + 带 alpha 的 colormap 实现边缘渐亮。
"""
function draw_atmosphere_glow!(axis;
    glow_factor::Float64 = 1.03,
    alpha_max::Float64 = 0.08,
)
    n_theta = 48
    n_phi = 24
    theta = range(0, 2pi; length = n_theta)
    phi = range(0, pi; length = n_phi)
    r_glow = EARTH_R * glow_factor
    ex = [r_glow * cos(t) * sin(p) for t in theta, p in phi]
    ey = [r_glow * sin(t) * sin(p) for t in theta, p in phi]
    ez = [r_glow * cos(p) for t in theta, p in phi]

    # 边缘（|z| 小的地方）alpha 高，正面 alpha 低 → 球缘辉光
    glow_field = abs.(ez ./ r_glow)
    surface!(axis, ex, ey, ez;
        color = glow_field,
        colormap = cgrad([:transparent, RGBAf(0.3, 0.6, 1.0, alpha_max)]),
        shading = NoShading,
        transparency = true,
    )
    return nothing
end

"""
    draw_coastlines!(axis; resolution, color, linewidth)

在 Axis3 上绘制海岸线。从 GeoMakie 加载 NaturalEarth 数据，
将 lat/lon 投影为 ECEF xyz。
"""
function draw_coastlines!(axis;
    resolution::Int = 110,
    color = :black,
    linewidth = 0.6,
)
    coast = _load_coastlines(resolution)

    if coast === :builtin
        # 使用内嵌简化海岸线
        for line in SIMPLIFIED_COASTLINES
            pts = Point3f[]
            for (lon, lat) in line
                x, y, z = latlon_to_xyz(lat, lon)
                push!(pts, Point3f(x, y, z))
            end
            length(pts) < 2 && continue
            lines!(axis, pts; color = color, linewidth = linewidth)
        end
    else
        # GeoMakie MultiLineString 格式
        for multiline in coast
            for line in multiline
                pts = Point3f[]
                for p in line
                    x, y, z = latlon_to_xyz(p[2], p[1])  # GeoMakie: p[1]=lon, p[2]=lat
                    push!(pts, Point3f(x, y, z))
                end
                length(pts) < 2 && continue
                lines!(axis, pts; color = color, linewidth = linewidth)
            end
        end
    end

    return nothing
end

"""
    draw_latlon_grid!(axis; color, linewidth, lat_step, lon_step)

在球面上绘制经纬网格线。
"""
function draw_latlon_grid!(axis;
    color = (:gray, 0.3),
    linewidth = 0.3,
    lat_step = 30,
    lon_step = 30,
)
    # 纬线
    for lat in -90:lat_step:90
        pts = [Point3f(latlon_to_xyz(lat, lon)...) for lon in -180:2:180]
        lines!(axis, pts; color = color, linewidth = linewidth)
    end

    # 经线
    for lon in -180:lon_step:180
        pts = [Point3f(latlon_to_xyz(lat, lon)...) for lat in -90:2:90]
        lines!(axis, pts; color = color, linewidth = linewidth)
    end

    return nothing
end

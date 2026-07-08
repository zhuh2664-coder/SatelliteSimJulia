# ===== 地球渲染 =====
#
# 用 GeoMakie.coastlines() 获取 NaturalEarth 海岸线数据，
# 手动投影到 3D 球面上（lat/lon → xyz），绘制在 Axis3 上。
# 兼容 CairoMakie（无头）和 GLMakie（交互）。

export draw_earth!, latlon_to_xyz, draw_coastlines!, draw_latlon_grid!

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
    draw_earth!(axis; resolution, coastline_color, ocean_color, land_color, show_coastlines)

在 Axis3 上绘制地球球面 + 海岸线。

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
)
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
        colormap = cgrad([ocean_color, RGBf(0.12, 0.35, 0.65)]),
        shading = NoShading,
    )

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
        # GeoMakie 返回 Vector{MultiLineString}；新版 GeometryBasics 里
        # MultiLineString/LineString 不再可直接迭代，需经 .linestrings/.points 访问。
        for multiline in coast
            for line in multiline.linestrings
                pts = Point3f[]
                for p in line.points
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

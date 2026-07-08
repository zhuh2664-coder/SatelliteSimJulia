# ===== 可视化配置结构 =====

export MakieViewerConfig, EarthViewerConfig

"""
    MakieViewerConfig(; kwargs...)

3D 轨道快照配置。所有字段都有对应的绘图行为。

# 字段
- `title::String` — 图标题
- `time_index::Int` — 显示哪个时间步（1-based）
- `show_orbits::Bool` — 绘制轨道轨迹线
- `show_isl::Bool` — 绘制 ISL 链路
- `show_gsl::Bool` — 绘制 GSL 连线
- `show_route::Bool` — 绘制路由路径高亮
- `show_ground_stations::Bool` — 绘制地面站
- `satellite_markersize::Float64` — 卫星散点大小
- `ground_markersize::Float64` — 地面站散点大小
- `orbit_linewidth::Float64` — 轨迹线宽
- `isl_linewidth::Float64` — ISL 链路线宽
- `route_linewidth::Float64` — 路由路径线宽
- `dark_theme::Bool` — 深空黑底风格（陆地填充 + 大气辉光）
- `show_beams::Bool` — 绘制卫星波束足迹
- `beam_angle_deg::Float64` — 波束半锥角（度）
"""
Base.@kwdef struct MakieViewerConfig
    title::String = "Satellite Network Viewer"
    time_index::Int = 1
    show_orbits::Bool = true
    show_isl::Bool = false
    show_gsl::Bool = false
    show_route::Bool = false
    show_ground_stations::Bool = true
    satellite_markersize::Float64 = 5.0
    ground_markersize::Float64 = 10.0
    orbit_linewidth::Float64 = 1.0
    isl_linewidth::Float64 = 0.8
    route_linewidth::Float64 = 3.0
    dark_theme::Bool = true
    show_beams::Bool = false
    beam_angle_deg::Float64 = 30.0
end

function MakieViewerConfig(title::AbstractString, time_index::Int)
    MakieViewerConfig(; title = String(title), time_index = time_index)
end

"""
    EarthViewerConfig(; kwargs...)

独立地球渲染配置。

# 字段
- `title::String` — 图标题
- `show_coastlines::Bool` — 绘制海岸线
- `show_grid::Bool` — 绘制经纬网格
- `rotation_deg::Float64` — 地球初始旋转角度（度）
"""
Base.@kwdef struct EarthViewerConfig
    title::String = "WGS84 Earth Viewer"
    show_coastlines::Bool = true
    show_grid::Bool = false
    rotation_deg::Float64 = 0.0
end

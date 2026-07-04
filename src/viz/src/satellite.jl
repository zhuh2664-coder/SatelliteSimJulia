# ===== 卫星绘制 =====
#
# 卫星散点、轨迹线的绘制函数。
# 输入用裸数组（Matrix{Float64} N×3），
# 不依赖 ConstellationEphemeris 类型。

export draw_satellites!, draw_orbit_trails!

"""
    draw_satellites!(axis, positions; markersize, color, label)

在 Axis3 上绘制卫星散点。

# 参数
- `positions::Matrix{Float64}` — N×3 ECEF 坐标 (km)
- `markersize` — 散点大小
- `color` — 颜色（支持单色或按轨道面着色的向量）
- `label` — 图例标签
"""
function draw_satellites!(axis, positions::AbstractMatrix{<:Real};
    markersize = 5.0,
    color = :orange,
    label = nothing,
)
    n = size(positions, 1)
    n == 0 && return nothing

    xs = positions[:, 1]
    ys = positions[:, 2]
    zs = positions[:, 3]

    if label === nothing
        scatter!(axis, xs, ys, zs;
            markersize = markersize,
            color = color,
            strokewidth = 0.3,
            strokecolor = :black,
        )
    else
        scatter!(axis, xs, ys, zs;
            markersize = markersize,
            color = color,
            label = label,
            strokewidth = 0.3,
            strokecolor = :black,
        )
    end

    return nothing
end

"""
    draw_orbit_trails!(axis, positions; linewidth, color, alpha, trail_subsample)

在 Axis3 上绘制所有卫星的轨迹线。

# 参数
- `positions::Array{Float64,3}` — N×T×3 ECEF 坐标 (km)，T 为时间步数
- `linewidth` — 线宽
- `color` — 颜色
- `alpha` — 透明度（0-1）
- `trail_subsample` — 每隔几个点取一个（减少绘制量）
"""
function draw_orbit_trails!(axis, positions::Array{Float64,3};
    linewidth = 1.0,
    color = (:gray30, 0.35),
    trail_subsample = 1,
)
    n_sat = size(positions, 1)
    n_time = size(positions, 2)
    n_sat == 0 && return nothing

    for i in 1:n_sat
        pts = Point3f[]
        for t in 1:trail_subsample:n_time
            x, y, z = positions[i, t, 1], positions[i, t, 2], positions[i, t, 3]
            push!(pts, Point3f(x, y, z))
        end
        length(pts) < 2 && continue
        lines!(axis, pts; linewidth = linewidth, color = color)
    end

    return nothing
end

"""
    draw_orbit_trails!(axis, positions::Matrix{Float64}; kwargs...)

单时间步 fallback：无法绘制轨迹（只有一个时间点），静默跳过。
"""
draw_orbit_trails!(axis, positions::AbstractMatrix{<:Real}; kwargs...) = nothing

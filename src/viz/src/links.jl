# ===== 链路可视化 =====
#
# ISL 链路连线、GSL 连线、路由路径高亮。
# 输入全部用裸数据结构，不依赖 ConstellationEphemeris。

export draw_isl_links!, draw_gsl_links!, draw_route_path!

"""
    draw_isl_links!(axis, sat_positions, isl_pairs, available_mask; kwargs...)

绘制 ISL 链路。可用链路用绿色实线，不可用链路用灰色虚线。

# 参数
- `sat_positions::Matrix{Float64}` — N×3 ECEF (km)，当前时刻所有卫星位置
- `isl_pairs::Vector{Tuple{Int,Int}}` — ISL 边列表（1-based 卫星 ID）
- `available_mask::Vector{Bool}` — 每条边是否可用
- `linewidth` — 线宽
- `color_available` — 可用链路颜色
- `color_unavailable` — 不可用链路颜色
"""
function draw_isl_links!(axis,
    sat_positions::AbstractMatrix{<:Real},
    isl_pairs::AbstractVector{<:Tuple},
    available_mask::AbstractVector{Bool};
    linewidth = 0.8,
    color_available = (:limegreen, 0.7),
    color_unavailable = (:gray50, 0.2),
)
    n_sat = size(sat_positions, 1)
    for (k, (i, j)) in enumerate(isl_pairs)
        (i < 1 || j < 1 || i > n_sat || j > n_sat) && continue
        avail = k <= length(available_mask) ? available_mask[k] : false
        x1, y1, z1 = sat_positions[i, 1], sat_positions[i, 2], sat_positions[i, 3]
        x2, y2, z2 = sat_positions[j, 1], sat_positions[j, 2], sat_positions[j, 3]
        if avail
            lines!(axis,
                [x1, x2], [y1, y2], [z1, z2];
                color = color_available,
                linewidth = linewidth,
                label = k == 1 ? "ISL (available)" : nothing,
            )
        else
            lines!(axis,
                [x1, x2], [y1, y2], [z1, z2];
                color = color_unavailable,
                linewidth = linewidth * 0.5,
                linestyle = :dash,
                label = k == 1 ? "ISL (blocked)" : nothing,
            )
        end
    end
    return nothing
end

"""
    draw_gsl_links!(axis, sat_positions, ground_xyz, gsl_mask; kwargs...)

绘制 GSL（地面站到卫星）连线。可用连线用蓝色实线。

# 参数
- `sat_positions::Matrix{Float64}` — N×3 ECEF (km)
- `ground_xyz::Matrix{Float64}` — G×3 ECEF (km)，地面站位置（已投影到球面）
- `gsl_mask::Matrix{Bool}` — N_sat × N_ground，是否可见
- `linewidth` — 线宽
- `color` — 连线颜色
"""
function draw_gsl_links!(axis,
    sat_positions::AbstractMatrix{<:Real},
    ground_xyz::AbstractMatrix{<:Real},
    gsl_mask::AbstractMatrix{Bool};
    linewidth = 0.8,
    color = (:dodgerblue, 0.6),
)
    n_sat = size(sat_positions, 1)
    n_ground = size(ground_xyz, 1)
    has_label = false

    for g in 1:n_ground
        gx, gy, gz = ground_xyz[g, 1], ground_xyz[g, 2], ground_xyz[g, 3]
        for s in 1:min(n_sat, size(gsl_mask, 1))
            (g > size(gsl_mask, 2)) && continue
            gsl_mask[s, g] || continue
            sx, sy, sz = sat_positions[s, 1], sat_positions[s, 2], sat_positions[s, 3]
            lines!(axis,
                [gx, sx], [gy, sy], [gz, sz];
                color = color,
                linewidth = linewidth,
                label = !has_label ? "GSL" : nothing,
            )
            has_label = true
        end
    end

    return nothing
end

"""
    draw_route_path!(axis, sat_positions, route_sat_ids; kwargs...)

高亮绘制路由路径（卫星到卫星的跳转序列）。

# 参数
- `sat_positions::Matrix{Float64}` — N×3 ECEF (km)
- `route_sat_ids::Vector{Int}` — 路由经过的卫星 ID 序列（1-based）
- `linewidth` — 线宽
- `color` — 路径颜色
"""
function draw_route_path!(axis,
    sat_positions::AbstractMatrix{<:Real},
    route_sat_ids::AbstractVector{Int};
    linewidth = 3.0,
    color = :red,
)
    length(route_sat_ids) < 2 && return nothing

    # 提取路径点
    pts = Point3f[]
    for sid in route_sat_ids
        (sid < 1 || sid > size(sat_positions, 1)) && continue
        push!(pts, Point3f(
            sat_positions[sid, 1],
            sat_positions[sid, 2],
            sat_positions[sid, 3],
        ))
    end
    length(pts) < 2 && return nothing

    lines!(axis, pts; color = color, linewidth = linewidth, label = "Route")

    # 路径节点用大标记
    scatter!(axis, pts;
        markersize = 8,
        color = color,
        strokecolor = :white,
        strokewidth = 1.0,
    )

    return nothing
end

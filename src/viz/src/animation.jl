# ===== 时间动画 =====
#
# 把静态渲染升级为时间序列动画 / 交互回放。
# 使用 Makie.Observable 驱动 time_index，用 linesegments! 批量绘制链路提升性能。
# 输入仍是裸数组 Array{Float64,3}，不依赖 ConstellationEphemeris。

export animate_orbit, interactive_orbit

# ────────────────────────────────────────────────────────────
# 预计算：把每帧需要画的链路/路由/卫星点提前算好
# ────────────────────────────────────────────────────────────

function _precompute_isl_segments(
    positions::Array{Float64,3},
    isl_pairs::AbstractVector{<:Tuple},
    isl_available::AbstractVector{Bool},
)
    n_time = size(positions, 2)
    avail = Vector{Vector{Point3f}}(undef, n_time)
    unavail = Vector{Vector{Point3f}}(undef, n_time)

    for t in 1:n_time
        a_pts = Point3f[]
        u_pts = Point3f[]
        for (k, (i, j)) in enumerate(isl_pairs)
            (i < 1 || j < 1 || i > size(positions, 1) || j > size(positions, 1)) && continue
            avail_flag = k <= length(isl_available) ? isl_available[k] : false
            p1 = Point3f(positions[i, t, 1], positions[i, t, 2], positions[i, t, 3])
            p2 = Point3f(positions[j, t, 1], positions[j, t, 2], positions[j, t, 3])
            if avail_flag
                push!(a_pts, p1, p2)
            else
                push!(u_pts, p1, p2)
            end
        end
        avail[t] = a_pts
        unavail[t] = u_pts
    end
    return avail, unavail
end

function _precompute_gsl_segments(
    positions::Array{Float64,3},
    gs_xyz::AbstractMatrix{<:Real},
    gsl_mask::AbstractMatrix{Bool},
)
    n_time = size(positions, 2)
    n_sat = size(positions, 1)
    n_ground = size(gs_xyz, 1)
    segments = Vector{Vector{Point3f}}(undef, n_time)

    for t in 1:n_time
        pts = Point3f[]
        for g in 1:n_ground
            gp = Point3f(gs_xyz[g, 1], gs_xyz[g, 2], gs_xyz[g, 3])
            for s in 1:min(n_sat, size(gsl_mask, 1))
                (g > size(gsl_mask, 2)) && continue
                gsl_mask[s, g] || continue
                sp = Point3f(positions[s, t, 1], positions[s, t, 2], positions[s, t, 3])
                push!(pts, gp, sp)
            end
        end
        segments[t] = pts
    end
    return segments
end

function _precompute_route_points(
    positions::Array{Float64,3},
    route_path::AbstractVector{Int},
)
    n_time = size(positions, 2)
    n_sat = size(positions, 1)
    valid_route = filter(sid -> 1 <= sid <= n_sat, route_path)
    points = Vector{Vector{Point3f}}(undef, n_time)

    for t in 1:n_time
        pts = Point3f[]
        for sid in valid_route
            push!(pts, Point3f(positions[sid, t, 1], positions[sid, t, 2], positions[sid, t, 3]))
        end
        points[t] = pts
    end
    return points
end

function _perp_basis(n::NTuple{3,Float64})
    nx, ny, nz = n
    ref = abs(nz) < 0.9 ? (0.0, 0.0, 1.0) : (1.0, 0.0, 0.0)
    ux = ref[2] * nz - ref[3] * ny
    uy = ref[3] * nx - ref[1] * nz
    uz = ref[1] * ny - ref[2] * nx
    lu = sqrt(ux^2 + uy^2 + uz^2)
    u = (ux / lu, uy / lu, uz / lu)
    v = (ny * u[3] - nz * u[2], nz * u[1] - nx * u[3], nx * u[2] - ny * u[1])
    return u, v
end

function _precompute_beam_segments(
    positions::Array{Float64,3};
    beam_angle_deg::Real = 30.0,
    n_points::Int = 32,
)
    R = EARTH_R
    n_sat = size(positions, 1)
    n_time = size(positions, 2)
    α = deg2rad(beam_angle_deg)
    segments = Vector{Vector{Point3f}}(undef, n_time)

    for t in 1:n_time
        pts = Point3f[]
        for s in 1:n_sat
            sx, sy, sz = positions[s, t, 1], positions[s, t, 2], positions[s, t, 3]
            d = sqrt(sx^2 + sy^2 + sz^2)
            d <= R && continue
            n = (sx / d, sy / d, sz / d)
            h = d * cos(α)
            h >= R && continue
            r = sqrt(R^2 - h^2)
            u, v = _perp_basis(n)
            circle = Point3f[]
            for k in 0:n_points
                θ = 2π * k / n_points
                cx = h * n[1] + r * (u[1] * cos(θ) + v[1] * sin(θ))
                cy = h * n[2] + r * (u[2] * cos(θ) + v[2] * sin(θ))
                cz = h * n[3] + r * (u[3] * cos(θ) + v[3] * sin(θ))
                push!(circle, Point3f(cx, cy, cz))
            end
            # linesegments：把闭合圆拆成连续线段对
            for k in 1:(length(circle) - 1)
                push!(pts, circle[k], circle[k + 1])
            end
        end
        segments[t] = pts
    end
    return segments
end

# ────────────────────────────────────────────────────────────
# 共享绘图构建：返回 (figure, axis, time_obs) 供动画/交互复用
# ────────────────────────────────────────────────────────────

function _build_animation_figure(
    positions::Array{Float64,3};
    ground_stations::AbstractVector{GroundStation} = GroundStation[],
    ground_xyz = nothing,
    isl_pairs::AbstractVector{<:Tuple} = Tuple{Int,Int}[],
    isl_available::AbstractVector{Bool} = Bool[],
    gsl_mask::Matrix{Bool} = Matrix{Bool}(undef, 0, 0),
    route_path::AbstractVector{Int} = Int[],
    config::MakieViewerConfig = MakieViewerConfig(),
)
    n_sat = size(positions, 1)
    n_time = size(positions, 2)
    n_time < 1 && throw(ArgumentError("positions 时间维度至少为 1"))

    time_obs = Observable(1)
    xs_obs = lift(t -> positions[:, t, 1], time_obs)
    ys_obs = lift(t -> positions[:, t, 2], time_obs)
    zs_obs = lift(t -> positions[:, t, 3], time_obs)

    figure = Figure(size = (960, 720))

    if config.dark_theme
        figure.scene.backgroundcolor[] = RGBf(0.0, 0.0, 0.05)
    end

    axis = Axis3(
        figure[1, 1],
        title = config.title,
        aspect = :data,
        xlabel = "ECEF x (km)",
        ylabel = "ECEF y (km)",
        zlabel = "ECEF z (km)",
    )

    if config.dark_theme
        axis.backgroundcolor = RGBf(0.0, 0.0, 0.05)
        axis.titlecolor = :white
        axis.xlabelcolor = :white
        axis.ylabelcolor = :white
        axis.zlabelcolor = :white
        axis.xticklabelcolor = :white
        axis.yticklabelcolor = :white
        axis.zticklabelcolor = :white
    end

    # 1. 地球
    draw_earth!(axis;
        show_coastlines = true,
        show_grid = false,
        dark_theme = config.dark_theme,
    )

    # 2. 轨迹线（静态）
    if config.show_orbits && n_time > 1
        draw_orbit_trails!(axis, positions;
            linewidth = config.orbit_linewidth,
            color = (:gray30, 0.3),
        )
    end

    # 3. ISL 链路（批量 linesegments + Observable）
    if config.show_isl && !isempty(isl_pairs)
        isl_avail, isl_unavail = _precompute_isl_segments(positions, isl_pairs, isl_available)
        isl_avail_obs = lift(t -> isl_avail[t], time_obs)
        isl_unavail_obs = lift(t -> isl_unavail[t], time_obs)

        linesegments!(axis, isl_avail_obs;
            color = (:limegreen, 0.7),
            linewidth = config.isl_linewidth,
        )
        linesegments!(axis, isl_unavail_obs;
            color = (:gray50, 0.2),
            linewidth = config.isl_linewidth * 0.5,
            linestyle = :dash,
        )
    end

    # 4. 地面站（静态）
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
        gsl_segments = _precompute_gsl_segments(positions, gs_xyz, gsl_mask)
        gsl_obs = lift(t -> gsl_segments[t], time_obs)
        linesegments!(axis, gsl_obs;
            color = (:dodgerblue, 0.6),
            linewidth = 0.8,
        )
    end

    # 6. 路由路径高亮
    if config.show_route && !isempty(route_path)
        route_points = _precompute_route_points(positions, route_path)
        route_obs = lift(t -> route_points[t], time_obs)
        lines!(axis, route_obs;
            color = :red,
            linewidth = config.route_linewidth,
        )
        scatter!(axis, route_obs;
            markersize = 8,
            color = :red,
            strokecolor = :white,
            strokewidth = 1.0,
        )
    end

    # 7. 波束足迹（预计算 + linesegments 动态更新）
    if config.show_beams
        beam_segments = _precompute_beam_segments(positions;
            beam_angle_deg = config.beam_angle_deg,
            n_points = 32,
        )
        beam_obs = lift(t -> beam_segments[t], time_obs)
        linesegments!(axis, beam_obs;
            color = config.dark_theme ? (:cyan, 0.35) : (:cyan, 0.5),
            linewidth = 1.0,
        )
    end

    # 8. 卫星散点
    scatter!(axis, xs_obs, ys_obs, zs_obs;
        markersize = config.satellite_markersize,
        color = :orange,
        strokewidth = 0.3,
        strokecolor = :black,
        label = "Satellite",
    )

    # 图例
    if config.show_isl || config.show_route || config.show_ground_stations
        Legend(figure[1, 1], axis)
    end

    return figure, axis, time_obs
end

# ────────────────────────────────────────────────────────────
# 公开 API：动画 MP4
# ────────────────────────────────────────────────────────────

"""
    animate_orbit(positions; kwargs...) -> String

生成 3D 轨道动画 MP4。核心入口接受 Array{Float64,3}（N×T×3 ECEF km）。

# 参数
- `positions::Array{Float64,3}` — N×T×3 ECEF (km)
- `output_path::String` — 输出 MP4 路径
- `fps::Int` — 帧率
- `ground_stations`, `ground_xyz`, `isl_pairs`, `isl_available`, `gsl_mask`, `route_path` — 同 plot_orbit_snapshot
- `config::MakieViewerConfig` — 同 plot_orbit_snapshot（time_index 被忽略）
"""
function animate_orbit(positions::Array{Float64,3};
    output_path::AbstractString = joinpath(@__DIR__, "..", "..", "..", "outputs", "viz", "orbit_animation.mp4"),
    fps::Int = 10,
    kwargs...,
)
    n_time = size(positions, 2)
    n_time < 2 && throw(ArgumentError("animate_orbit 需要至少 2 个时间步，当前 n_time=" * string(n_time)))

    figure, axis, time_obs = _build_animation_figure(positions; kwargs...)
    mkpath(dirname(output_path))

    record(figure, output_path, 1:n_time; framerate = fps) do t
        time_obs[] = t
    end

    return output_path
end

# ────────────────────────────────────────────────────────────
# 公开 API：交互回放（GLMakie）
# ────────────────────────────────────────────────────────────

"""
    interactive_orbit(positions; kwargs...) -> (Figure, Observable{Int})

创建带时间滑块的交互式 3D 轨道回放窗口。需要 GLMakie 后端。
返回 (figure, time_obs)，用户可在外部继续绑定其他动态图层。

# 参数
- `positions::Array{Float64,3}` — N×T×3 ECEF (km)
- `config::MakieViewerConfig` — 同 plot_orbit_snapshot
- 其他 kwargs 同 animate_orbit
"""
function interactive_orbit(positions::Array{Float64,3};
    config::MakieViewerConfig = MakieViewerConfig(),
    kwargs...,
)
    n_time = size(positions, 2)
    n_time < 1 && throw(ArgumentError("interactive_orbit 需要至少 1 个时间步"))

    figure, axis, time_obs = _build_animation_figure(positions; config = config, kwargs...)

    # 滑块放在 figure 底部
    sl = Slider(figure[2, 1];
        range = 1:n_time,
        startvalue = 1,
    )
    connect!(time_obs, sl.value)

    # 标题随时间更新
    on(time_obs) do t
        axis.title = config.title * " — t=" * string(t)
    end

    return figure, time_obs
end

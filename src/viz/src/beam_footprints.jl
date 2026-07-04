# ===== 波束足迹 =====
#
# 在 3D 地球表面绘制卫星波束覆盖圈（cone-sphere intersection）。
# 输入裸数组，不依赖星座类型。

export draw_beam_footprint!, draw_beam_footprints!

"""
    _perpendicular_basis(n::NTuple{3,Float64}) -> (u, v)

给定向量 n，返回两个与它正交的单位向量 u, v，且 (u, v, n) 成右手系。
"""
function _perpendicular_basis(n::NTuple{3,Float64})
    nx, ny, nz = n
    # 找一个与 n 不平行的参考向量
    if abs(nz) < 0.9
        ref = (0.0, 0.0, 1.0)
    else
        ref = (1.0, 0.0, 0.0)
    end
    # u = ref × n，再单位化
    ux = ref[2] * nz - ref[3] * ny
    uy = ref[3] * nx - ref[1] * nz
    uz = ref[1] * ny - ref[2] * nx
    len_u = sqrt(ux^2 + uy^2 + uz^2)
    u = (ux / len_u, uy / len_u, uz / len_u)

    # v = n × u
    vx = ny * u[3] - nz * u[2]
    vy = nz * u[1] - nx * u[3]
    vz = nx * u[2] - ny * u[1]
    v = (vx, vy, vz)

    return u, v
end

"""
    draw_beam_footprint!(axis, sat_position; beam_angle_deg, n_points, color, linewidth)

在 3D 地球表面绘制单个卫星的波束足迹边界圈。

# 参数
- `sat_position::NTuple{3,Real}` 或 `AbstractVector{<:Real}` — 卫星 ECEF (km)
- `beam_angle_deg::Real` — 波束半锥角（度），默认 30°
- `n_points::Int` — 圆上采样点数
"""
function draw_beam_footprint!(axis, sat_position;
    beam_angle_deg::Real = 30.0,
    n_points::Int = 48,
    color = (:cyan, 0.5),
    linewidth = 1.2,
)
    R = EARTH_R
    sx, sy, sz = float.(sat_position)
    d = sqrt(sx^2 + sy^2 + sz^2)
    d <= R && return nothing  # 卫星在地表或地下，不画

    n = (sx / d, sy / d, sz / d)
    α = deg2rad(beam_angle_deg)

    # 锥面与地球球面交线圆所在平面，距离地心 h
    h = d * cos(α)
    if h >= R
        # 波束未切到地球表面（指向太空或切点不存在）
        return nothing
    end
    r = sqrt(R^2 - h^2)

    u, v = _perpendicular_basis(n)

    pts = Point3f[]
    for k in 0:n_points
        θ = 2π * k / n_points
        cx = h * n[1] + r * (u[1] * cos(θ) + v[1] * sin(θ))
        cy = h * n[2] + r * (u[2] * cos(θ) + v[2] * sin(θ))
        cz = h * n[3] + r * (u[3] * cos(θ) + v[3] * sin(θ))
        push!(pts, Point3f(cx, cy, cz))
    end

    lines!(axis, pts; color = color, linewidth = linewidth)
    return nothing
end

"""
    draw_beam_footprints!(axis, sat_positions; beam_angle_deg, kwargs...)

批量绘制所有卫星的波束足迹。

# 参数
- `sat_positions::Matrix{Float64}` — N×3 ECEF (km)
"""
function draw_beam_footprints!(axis, sat_positions::AbstractMatrix{<:Real};
    beam_angle_deg::Real = 30.0,
    n_points::Int = 48,
    color = (:cyan, 0.4),
    linewidth = 1.0,
)
    n_sat = size(sat_positions, 1)
    for i in 1:n_sat
        draw_beam_footprint!(axis,
            (sat_positions[i, 1], sat_positions[i, 2], sat_positions[i, 3]);
            beam_angle_deg = beam_angle_deg,
            n_points = n_points,
            color = color,
            linewidth = linewidth,
        )
    end
    return nothing
end

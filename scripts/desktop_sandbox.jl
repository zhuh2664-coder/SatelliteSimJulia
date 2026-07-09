#!/usr/bin/env julia
# ============================================================
# desktop_sandbox.jl — 纯 Julia 3D 沙盒（GLMakie，不需要 Unity）
# ============================================================
#
# 用法：
#   julia --project=. scripts/desktop_sandbox.jl                  # 默认 iridium
#   julia --project=. scripts/desktop_sandbox.jl walker24
#   julia --project=. scripts/desktop_sandbox.jl oneweb
#
# 第一次跑会自动装 GLMakie 到主 Project.toml（约 30-60s）。之后秒开。
# 交互：鼠标拖动旋转、滚轮缩放、右键平移；底部滑块控制时间步。

using Pkg

# ── 1. 确保 GLMakie 可用（必要时自动装到主 env） ─────────
try
    using GLMakie
catch
    @info "首次运行：正在装 GLMakie（约 30-60 秒，一次性）..."
    Pkg.add("GLMakie")
    using GLMakie
end

using SatelliteSimCore

# ── 2. 选星座（CLI 参数） ─────────────────────────────────
const CNAME = get(ARGS, 1, "iridium")
const SYM = Symbol(CNAME)

config = resolve_constellation(SYM)
elems = generate_walker_delta(; T=config.T, P=config.P, F=config.F,
                               alt_km=config.alt_km, inc_deg=config.inc_deg)
positions = propagate_to_ecef(elems, (0.0, 600.0); propagator=:j2)
n_sat, n_time = size(positions, 1), size(positions, 2)
@info "Loaded constellation" name=CNAME n_sat=n_sat n_time=n_time

topo = generate_topology(GridPlusStrategy(), config.T, config.P)
isl_pairs = vcat(topo.static_links, topo.dynamic_candidates)
constraints = LEO_DEFAULTS

# 缩放：1 unit = 1000 km，地球半径 ~6.4 units
const S = 1.0 / 1000.0
const R = 6378.137 * S
pos_s = positions .* S

# ── 3. 建图 ───────────────────────────────────────────────
fig = Figure(size=(1200, 800), backgroundcolor=:black)
ax = Axis3(fig[1, 1],
    title = "SatelliteSim Sandbox — $CNAME",
    aspect = :data,
    xlabel = "x (×1000 km)", ylabel = "y (×1000 km)", zlabel = "z (×1000 km)",
    backgroundcolor = RGBf(0.05, 0.05, 0.08),
    xlabelcolor=:white, ylabelcolor=:white, zlabelcolor=:white,
    titlecolor=:white, xticklabelcolor=:white, yticklabelcolor=:white, zticklabelcolor=:white,
)

# 地球（简单蓝色球 + 经纬线）
n_lat, n_lon = 32, 64
u = range(0, π, length=n_lat)
v = range(0, 2π, length=n_lon)
xs = [R * sin(ui) * cos(vi) for ui in u, vi in v]
ys = [R * sin(ui) * sin(vi) for ui in u, vi in v]
zs = [R * cos(ui) for ui in u, vi in v]
mesh!(ax, xs, ys, zs; color=(:steelblue, 0.85), shading=true)
for lat in (-60, -30, 0, 30, 60)
    φ = deg2rad(lat + 90)
    rr = R * sin(φ); yy = R * cos(φ)
    θ = range(0, 2π, length=64)
    lines!(ax, rr .* cos.(θ), rr .* sin.(θ), fill(yy, length(θ));
           color=(:white, 0.15), linewidth=0.5)
end
for lon in 0:30:330
    θ = deg2rad(lon)
    φ = range(0, π, length=64)
    lines!(ax, R .* sin.(φ) .* cos(θ), R .* sin.(φ) .* sin(θ), R .* cos.(φ);
           color=(:white, 0.15), linewidth=0.5)
end

# 时间驱动
time_obs = Observable(1)
xs_obs = @lift(pos_s[:, $time_obs, 1])
ys_obs = @lift(pos_s[:, $time_obs, 2])
zs_obs = @lift(pos_s[:, $time_obs, 3])

# 卫星散点
scatter!(ax, xs_obs, ys_obs, zs_obs; markersize=6, color=:orange,
         label="Sat", strokewidth=0.3, strokecolor=:black)

# 轨道轨迹
for i in 1:n_sat
    lines!(ax, pos_s[i, :, 1], pos_s[i, :, 2], pos_s[i, :, 3];
           color=(:gray40, 0.4), linewidth=0.5)
end

# ISL 边（实时更新端点）
for (k, (i, j)) in enumerate(isl_pairs)
    x1 = @lift(pos_s[i, $time_obs, 1])
    y1 = @lift(pos_s[i, $time_obs, 2])
    z1 = @lift(pos_s[i, $time_obs, 3])
    x2 = @lift(pos_s[j, $time_obs, 1])
    y2 = @lift(pos_s[j, $time_obs, 2])
    z2 = @lift(pos_s[j, $time_obs, 3])
    lines!(ax, [x1, x2], [y1, y2], [z1, z2];
           color=(:limegreen, 0.5), linewidth=0.6)
end

# 顶部 HUD
Label(fig[0, 1],
      "$CNAME  |  $(n_sat) sats  |  $(n_time) frames  |  ISL: $(length(isl_pairs))",
      color=:white, fontsize=14, halign=:left)

# 底部时间滑块
sg = SliderGrid(fig[2, 1], (label="Frame", range=1:n_time, startvalue=1, linewidth=400))
connect!(time_obs, sg.slider.value)

display(fig)

# ── 4. 自动播放循环 ───────────────────────────────────────
@async begin
    while isopen(fig.scene)
        for t in 1:n_time
            isopen(fig.scene) || return
            time_obs[] = t
            sleep(0.1)
        end
    end
end

# 阻塞直到窗口关闭
wait(fig.scene)

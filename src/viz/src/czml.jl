# ===== CZML 导出 =====
#
# 将位置矩阵导出为 Cesium CZML 格式（JSON），可用 CesiumJS 加载。
# 输入位置沿用项目内部 ECEF km，写入 CZML 时转换为 Cesium 使用的 m。
# 支持：
#   - 卫星点（position + point 属性）
#   - ISL 链路（polyline 属性）
#   - 地面站（固定点）
#
# CZML 规范: https://github.com/AnalyticalGraphicsInc/czml-writer/wiki/Packet

export to_czml, write_czml

using JSON

# ────────────────────────────────────────────────────────────
# 简单 ISO 8601 构造（不依赖 Dates stdlib）
# ────────────────────────────────────────────────────────────

const ISO_DAY_1 = "2000-01-01T12:00:00Z"

_czml_meters(x) = Float64(x) * 1000.0

_isleap_year(y::Int) = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
_days_in_month(y::Int, m::Int) = m == 2 ? (_isleap_year(y) ? 29 : 28) :
    m in (4, 6, 9, 11) ? 30 : 31
_pad2(n::Int) = lpad(string(n), 2, '0')

"""epoch 后 elapsed 秒的 ISO 8601 字符串（截断到整秒）。"""
function _iso_time(epoch_iso::String, elapsed::Float64)
    elapsed < 0 && error("elapsed must be non-negative")
    length(epoch_iso) >= 20 || error("epoch must be ISO 8601 like 2000-01-01T12:00:00Z")

    y = parse(Int, epoch_iso[1:4])
    m = parse(Int, epoch_iso[6:7])
    d = parse(Int, epoch_iso[9:10])
    h = parse(Int, epoch_iso[12:13])
    minute = parse(Int, epoch_iso[15:16])
    sec = parse(Int, epoch_iso[18:19]) + round(Int, elapsed)

    minute += sec ÷ 60
    sec %= 60
    h += minute ÷ 60
    minute %= 60
    d += h ÷ 24
    h %= 24

    while d > _days_in_month(y, m)
        d -= _days_in_month(y, m)
        m += 1
        if m > 12
            m = 1
            y += 1
        end
    end

    return string(y, "-", _pad2(m), "-", _pad2(d), "T",
        _pad2(h), ":", _pad2(minute), ":", _pad2(sec), "Z")
end

# ────────────────────────────────────────────────────────────
# to_czml
# ────────────────────────────────────────────────────────────

"""
    to_czml(positions; kwargs...) -> String

将 N×T×3 ECEF (km) 位置矩阵导出为 CZML JSON 字符串；CZML 坐标单位为 m。

# 参数
- `positions::Array{Float64,3}` — N×T×3 ECEF 位置 (km)，导出时转换为 m
- `epoch::String` — 起始 UTC 时间（ISO 8601，默认 "2000-01-01T12:00:00Z"）
- `dt::Float64` — 相邻采样间隔（秒，默认 60）
- `isl_pairs::Vector{Tuple{Int,Int}}` — 静态 ISL 边
- `ground_stations::Vector{GroundStation}` — 地面站
- `ground_xyz::Matrix{Float64}` — 预计算的地面站 G×3 ECEF (km)
"""
function to_czml(positions::Array{Float64,3};
    epoch::String = ISO_DAY_1,
    dt::Float64 = 60.0,
    isl_pairs::AbstractVector{<:Tuple} = Tuple{Int,Int}[],
    ground_stations = nothing,
    ground_xyz = nothing,
)
    N, T, _ = size(positions)

    packets = Dict{String,Any}[]

    # ── Document packet ──
    t0 = epoch
    t_end = _iso_time(epoch, (T - 1) * dt)
    push!(packets, Dict(
        "id" => "document",
        "version" => "1.0",
        "name" => "SatelliteSimJulia export",
        "clock" => Dict(
            "interval" => "$t0/$t_end",
            "currentTime" => t0,
            "multiplier" => 1,
        ),
    ))

    # ── 卫星 packets ──
    for i in 1:N
        cart = Float64[]
        for t_idx in 1:T
            push!(cart, (t_idx - 1) * dt)
            push!(cart, _czml_meters(positions[i, t_idx, 1]))
            push!(cart, _czml_meters(positions[i, t_idx, 2]))
            push!(cart, _czml_meters(positions[i, t_idx, 3]))
        end
        push!(packets, Dict(
            "id" => "satellite/$i",
            "name" => "Satellite $i",
            "availability" => "$t0/$t_end",
            "position" => Dict(
                "referenceFrame" => "FIXED",
                "interpolationAlgorithm" => "LAGRANGE",
                "interpolationDegree" => 1,
                "epoch" => t0,
                "cartesian" => cart,
            ),
            "point" => Dict(
                "color" => Dict("rgba" => [255, 165, 0, 255]),
                "pixelSize" => 5,
            ),
            "label" => Dict(
                "text" => "$i",
                "font" => "12pt sans-serif",
                "style" => "FILL",
                "fillColor" => Dict("rgba" => [255, 255, 255, 255]),
                "pixelOffset" => Dict("cartesian2" => [0, 12]),
            ),
        ))
    end

    # ── ISL packets ──
    if !isempty(isl_pairs)
        mid_idx = div(T, 2) + 1
        for (k, pair) in enumerate(isl_pairs)
            a, b = Int(pair[1]), Int(pair[2])
            (a < 1 || a > N || b < 1 || b > N) && continue
            p1 = positions[a, mid_idx, :]
            p2 = positions[b, mid_idx, :]
            push!(packets, Dict(
                "id" => "isl/$k",
                "name" => "ISL $a→$b",
                "availability" => "$t0/$t_end",
                "polyline" => Dict(
                    "positions" => Dict(
                        "referenceFrame" => "FIXED",
                        "cartesian" => [_czml_meters(p1[1]), _czml_meters(p1[2]), _czml_meters(p1[3]),
                                        _czml_meters(p2[1]), _czml_meters(p2[2]), _czml_meters(p2[3])],
                    ),
                    "material" => Dict(
                        "solidColor" => Dict(
                            "color" => Dict("rgba" => [0, 255, 255, 128])
                        ),
                    ),
                    "width" => 1.0,
                ),
            ))
        end
    end

    # ── 地面站 packets ──
    gs_xyz = nothing
    if ground_xyz !== nothing
        gs_xyz = ground_xyz
    elseif ground_stations !== nothing && !isempty(ground_stations)
        gs_xyz = zeros(Float64, length(ground_stations), 3)
        for (j, gs) in enumerate(ground_stations)
            x, y, z = latlon_to_xyz(gs.position.latitude_deg, gs.position.longitude_deg;
                alt_km = gs.position.altitude_km)
            gs_xyz[j, 1] = x
            gs_xyz[j, 2] = y
            gs_xyz[j, 3] = z
        end
    end

    if gs_xyz !== nothing && size(gs_xyz, 1) > 0
        for j in 1:size(gs_xyz, 1)
            push!(packets, Dict(
                "id" => "groundstation/$j",
                "name" => "GS $j",
                "position" => Dict(
                    "referenceFrame" => "FIXED",
                    "cartesian" => [_czml_meters(gs_xyz[j, 1]), _czml_meters(gs_xyz[j, 2]), _czml_meters(gs_xyz[j, 3])],
                ),
                "point" => Dict(
                    "color" => Dict("rgba" => [30, 144, 255, 255]),
                    "pixelSize" => 10,
                    "outlineColor" => Dict("rgba" => [255, 255, 255, 128]),
                    "outlineWidth" => 2,
                ),
            ))
        end
    end

    return JSON.json(packets)
end

# ────────────────────────────────────────────────────────────
# write_czml
# ────────────────────────────────────────────────────────────

"""
    write_czml(path, positions; kwargs...) -> path

导出 CZML 到文件。
"""
function write_czml(path::AbstractString, positions::Array{Float64,3}; kwargs...)
    json_str = to_czml(positions; kwargs...)
    open(path, "w") do io
        write(io, json_str)
    end
    return path
end

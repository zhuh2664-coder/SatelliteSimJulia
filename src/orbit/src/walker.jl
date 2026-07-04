# ===== Walker-Delta 星座构型生成 =====
# 输入 T/P/F + 高度/倾角 → 输出 Satellite 列表 + ECI 位置
# 算法来自 src/core/network_layer/design_orbit_generation.jl

using SatelliteToolbox: KeplerianElements, EARTH_EQUATORIAL_RADIUS

export generate_walker_delta

"""
    generate_walker_delta(; T, P, F, alt_km, inc_deg, raan_spread=:auto) -> Vector{KeplerianElements}

生成 Walker-Delta 星座的轨道根数列表。

# 参数
- `T::Int`: 卫星总数
- `P::Int`: 轨道面数
- `F::Int`: 相位因子 (0 ≤ F < P)
- `alt_km::Float64`: 轨道高度 (km)
- `inc_deg::Float64`: 轨道倾角 (度)
- `raan_spread::Symbol`: RAAN 展开策略 `:auto`（极轨 180°，其它 360°）或 `:full`（360°）

# 返回值
`Vector{KeplerianElements}` — 每颗卫星的 Kepler 根数，顺序为 (plane1_sat1, plane1_sat2, ..., plane2_sat1, ...)
"""
# [算法说明]
# Walker-Delta 星座参数（来自 design_orbit_generation.jl）：
#   T = P × S  (S = 每面卫星数)
#   RAAN_i = (i-1) × RAAN_span / P,  i = 1..P
#   M_j = (j-1) × 360°/S + (i-1) × F × 360°/T,  j = 1..S
#   极轨 (inc ≈ 90°): RAAN_span = 180°（避免极点密集）
#   非极轨: RAAN_span = 360°
function generate_walker_delta(;
    T::Int, P::Int, F::Int,
    alt_km::Float64=550.0, inc_deg::Float64=53.0,
    raan_spread::Symbol=:auto
)
    T > 0 || throw(ArgumentError("T must be positive"))
    1 ≤ P ≤ T || throw(ArgumentError("P must be in [1, T]"))
    0 ≤ F < P || throw(ArgumentError("F must be in [0, P-1]"))

    S = div(T, P)            # 每面卫星数
    T == P * S || throw(ArgumentError("T must be divisible by P"))

    # RAAN 展开范围
    span = if raan_spread == :auto
        abs(inc_deg - 90) < 1 ? 180.0 : 360.0
    else
        360.0
    end

    a_m = EARTH_EQUATORIAL_RADIUS + alt_km * 1000  # 轨道半长轴 (m)

    elems = KeplerianElements[]
    for p in 1:P
        raan = (p - 1) * span / P
        for s in 1:S
            ma = mod(360 * (s - 1) / S + 360 * (p - 1) * F / T, 360)
            # 近圆轨道 (ecc≈0) 下真近点角 ≈ 平近点角
            push!(elems, KeplerianElements(
                0.0,           # epoch t (Number)
                a_m,           # 半长轴 (m)
                0.001,         # 偏心率 (≈ 圆轨道)
                deg2rad(inc_deg),
                deg2rad(raan),
                0.0,           # 近地点幅角
                deg2rad(ma),   # f = 真近点角，圆轨 ≈ 平近点角
            ))
        end
    end
    return elems
end

"""
    generate_satellite_ids(prefix, T) -> Vector{String}

生成卫星 ID 列表。
"""
function generate_satellite_ids(prefix::String="sat", T::Int=24)
    return ["$(prefix)-$(lpad(i,4,'0'))" for i in 1:T]
end

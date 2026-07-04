# ===== 星座目录 =====
# 统一配置: Walker (理想) + TLE (真实) 放在一起，通过 :source 区分。
# 构造流程: catalog → build_constellation() → Vector{SatelliteInstance}

export WalkerConstellationConfig, TLEConstellationConfig, list_constellations, resolve_constellation

abstract type AbstractConstellationConfig end

Base.@kwdef struct WalkerConstellationConfig <: AbstractConstellationConfig
    T::Int
    P::Int
    F::Int
    alt_km::Float64
    inc_deg::Float64
end

Base.@kwdef struct TLEConstellationConfig <: AbstractConstellationConfig
    tle_path::String
end

const CONSTELLATION_CATALOG = Dict{Symbol,AbstractConstellationConfig}(

    # ── Walker 设计星座 ──
    :walker24 => WalkerConstellationConfig(
        T=24, P=6, F=1, alt_km=550.0, inc_deg=53.0,
    ),
    :walker48 => WalkerConstellationConfig(
        T=48, P=8, F=2, alt_km=550.0, inc_deg=53.0,
    ),
    :walker72 => WalkerConstellationConfig(
        T=72, P=8, F=2, alt_km=550.0, inc_deg=53.0,
    ),
    :walker96 => WalkerConstellationConfig(
        T=96, P=12, F=3, alt_km=550.0, inc_deg=53.0,
    ),
    :kuiper => WalkerConstellationConfig(
        T=1156, P=34, F=1, alt_km=630.0, inc_deg=51.9,
    ),

    # ── Starlink 壳层 ──
    :starlink_gen1 => WalkerConstellationConfig(
        T=1584, P=72, F=1, alt_km=550.0, inc_deg=53.0,
    ),
    :starlink_2a_1 => WalkerConstellationConfig(
        T=1680, P=14, F=1, alt_km=530.0, inc_deg=43.0,
    ),

    # ── OneWeb (Phase 1) — 调研 §7.3: 1200km/87.9° ──
    :oneweb => WalkerConstellationConfig(
        T=648, P=12, F=1, alt_km=1200.0, inc_deg=87.9,
    ),

    # ── Iridium NEXT — 调研 §7.3: 780km/86.4°, 6×11=66 ──
    :iridium => WalkerConstellationConfig(
        T=66, P=6, F=2, alt_km=780.0, inc_deg=86.4,
    ),

    # ── Telesat Lightspeed (Phase 1) — 调研 §7.3: 1015km/99.1° 极轨太阳同步 ──
    :telesat => WalkerConstellationConfig(
        T=117, P=6, F=1, alt_km=1015.0, inc_deg=99.1,
    ),

    # ── GW (中国星网) — 参数基于公开 ITU 申报，待确认 ──
    :gw_shell1 => WalkerConstellationConfig(
        T=1296, P=36, F=1, alt_km=590.0, inc_deg=55.0,
    ),
    :gw_shell2 => WalkerConstellationConfig(
        T=1296, P=36, F=1, alt_km=600.0, inc_deg=40.0,
    ),

    # ── 千帆 (G60) — 上海垣信，首批参数基于公开报道，待确认 ──
    :qianfan_phase1 => WalkerConstellationConfig(
        T=1296, P=36, F=1, alt_km=1160.0, inc_deg=50.0,
    ),

    # ── TLE 真实星座 ──
    # 注意：@__DIR__ 是 src/core/src/shared/catalog/，到仓库根需回溯 5 级。
    # （bugfix：原 3 级回溯会解析到 src/core/data/，文件不存在）
    :starlink_tle => TLEConstellationConfig(
        tle_path=joinpath(@__DIR__, "..", "..", "..", "..", "..", "data", "tle", "celestrak", "starlink_gp_latest.tle"),
    ),
)

function resolve_constellation(sym::Symbol)
    haskey(CONSTELLATION_CATALOG, sym) || error("unknown constellation: $sym")
    return CONSTELLATION_CATALOG[sym]
end

list_constellations() = sort(collect(keys(CONSTELLATION_CATALOG)))

# ===== 星座构建器（简化版） =====
# 合并 builders_core.jl + design_orbit.jl 的核心功能
# 使用新的类型系统：SatelliteId = Int, Constellation = Vector{Satellite}

using Statistics
import SatelliteToolbox

export AbstractConstellationBuilder, DesignConstellationBuilder, TLEConstellationBuilder
# export build_constellation, generate_walker_constellation

"""
    AbstractConstellationBuilder

星座构建器抽象基类型。
"""
abstract type AbstractConstellationBuilder end

"""
    DesignConstellationBuilder <: AbstractConstellationBuilder

根据设计规格构建星座的构建器。
"""
struct DesignConstellationBuilder <: AbstractConstellationBuilder
    source::String
end

DesignConstellationBuilder() = DesignConstellationBuilder("design")

"""
    TLEConstellationBuilder <: AbstractConstellationBuilder

根据 TLE 数据构建星座的构建器。
"""
struct TLEConstellationBuilder <: AbstractConstellationBuilder
    source::String
end

TLEConstellationBuilder() = TLEConstellationBuilder("tle")

"""
    generate_walker_constellation(; T, P, F, alt_km, inc_deg, name_prefix="sat") -> Vector{Satellite}

生成 Walker-Delta 星座。

# 参数
- `T::Int`: 卫星总数
- `P::Int`: 轨道面数
- `F::Int`: 相位因子 (0 ≤ F < P)
- `alt_km::Float64`: 轨道高度 (km)
- `inc_deg::Float64`: 轨道倾角 (度)
- `name_prefix::String`: 卫星名称前缀

# 返回值
`Vector{Satellite}` — 卫星列表，id 从 1 到 T
"""
function generate_walker_constellation(;
    T::Int, P::Int, F::Int,
    alt_km::Float64=550.0, inc_deg::Float64=53.0,
    name_prefix::String="sat"
)
    T > 0 || throw(ArgumentError("T must be positive"))
    1 ≤ P ≤ T || throw(ArgumentError("P must be in [1, T]"))
    0 ≤ F < P || throw(ArgumentError("F must be in [0, P-1]"))

    S = div(T, P)  # 每面卫星数
    T == P * S || throw(ArgumentError("T must be divisible by P"))

    # RAAN 展开范围（极轨用180°，其他用360°）
    raan_span = abs(inc_deg - 90) < 10 ? 180.0 : 360.0

    satellites = Vector{Satellite}()
    sizehint!(satellites, T)

    sat_id = 1
    for p in 1:P
        # 轨道面 RAAN
        raan = (p - 1) * raan_span / P

        for s in 1:S
            # 平均近点角（含相位偏移）
            ma = mod(360 * (s - 1) / S + 360 * (p - 1) * F / T, 360)

            # 创建轨道根数
            orbit = DesignOrbitElementSet(
                altitude_km=alt_km,
                inclination_deg=inc_deg,
                eccentricity=0.001,  # 近圆轨道
                raan_deg=raan,
                argument_of_perigee_deg=0.0,
                mean_anomaly_deg=ma
            )

            # 创建卫星
            sat = Satellite(
                id=sat_id,
                name="$(name_prefix)-$(lpad(sat_id, 4, '0'))",
                orbit=orbit,
                config=SatelliteConfig()
            )

            push!(satellites, sat)
            sat_id += 1
        end
    end

    return satellites
end

"""
    build_constellation(builder::DesignConstellationBuilder; kwargs...) -> Vector{Satellite}

使用设计构建器构建星座。
"""
function build_constellation(builder::DesignConstellationBuilder; kwargs...)
    return generate_walker_constellation(; kwargs...)
end

"""
    build_constellation(builder::TLEConstellationBuilder, tle_records::Vector{TLERecordSpec}) -> Vector{Satellite}

使用 TLE 构建器构建星座。
"""
function build_constellation(builder::TLEConstellationBuilder, tle_records::Vector{TLERecordSpec})
    satellites = Vector{Satellite}()
    sizehint!(satellites, length(tle_records))

    for (i, record) in enumerate(tle_records)
        orbit = TLEOrbitElementSet(record.name, record.line1, record.line2)
        sat = Satellite(
            id=i,
            name=record.name,
            orbit=orbit,
            config=SatelliteConfig()
        )
        push!(satellites, sat)
    end

    return satellites
end

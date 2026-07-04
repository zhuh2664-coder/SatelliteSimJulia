# ===== 实验抽象层 — 多分派可扩展 =====
# 新增实验只需: 1) 定义子类型 2) 实现 run/describe 3) 注册
#
# 模式:
#   struct MyExp <: AbstractExperiment end
#   SatelliteSimLab.run(::MyExp) = ...
#   SatelliteSimLab.describe(::MyExp) = "分析 X 对 Y 的影响"
#   SatelliteSimLab.register!(MyExp())

export AbstractExperiment,
       run, describe, cli_schema, register!, registered_experiments,
       DeadZoneScan

abstract type AbstractExperiment end

"""所有实验的注册表（CLI 自动发现用）"""
const EXPERIMENT_REGISTRY = Dict{String, AbstractExperiment}()

"""注册一个实验实例（CLI 可通过名称调用）"""
function register!(exp::AbstractExperiment, name::String)
    EXPERIMENT_REGISTRY[name] = exp
    return exp
end

"""列出所有已注册实验"""
registered_experiments() = sort(collect(keys(EXPERIMENT_REGISTRY)))

"""运行实验（子类型必须实现）"""
function run(exp::AbstractExperiment, config::ExperimentConfig)
    error("未实现 run(::$(typeof(exp)), ...)")
end

"""返回实验的人类可读描述"""
function describe(exp::AbstractExperiment)
    return string(typeof(exp))
end

"""返回 LLM tool schema（供 SimCLI 自动生成工具定义）"""
function cli_schema(exp::AbstractExperiment, name::String)
    desc = describe(exp)
    return Dict(
        "name" => name,
        "description" => desc,
        "input_schema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "constellation" => Dict("type" => "string", "description" => "星座名称"),
                "steps" => Dict("type" => "integer", "default" => 30),
            ),
        ),
    )
end

# ============================================================
# 实验 01: ISL 死区检测
# ============================================================
struct DeadZoneScan <: AbstractExperiment
    altitudes::Vector{Float64}
    spp::Int
    inc_deg::Float64
    threshold_km::Float64
end

DeadZoneScan(; altitudes=[550, 800, 1200], spp=4, inc_deg=60, threshold_km=4000) =
    DeadZoneScan(Float64.(altitudes), spp, Float64(inc_deg), Float64(threshold_km))

describe(::DeadZoneScan) = """
ISL 死区检测：扫描 Walker 星座相邻轨道面的 RAAN 间隙，
发现在 ΔΩ ≈ 60° 时跨面 ISL 数量骤降（几何固有盲区）。
"""

function run(exp::DeadZoneScan, config::ExperimentConfig)
    RE = SatelliteSimCore.WGS84_EQUATORIAL_RADIUS_KM
    MU = SatelliteSimCore.MU_KM3_S2
    inc_rad = deg2rad(exp.inc_deg)
    ci, si = cos(inc_rad), sin(inc_rad)
    mas = [mod(i * 360.0 / exp.spp, 360) for i in 0:exp.spp-1]

    results = Dict{Float64, Vector{Float64}}()
    for alt in exp.altitudes
        ro = RE + alt
        per = 2π * sqrt(ro^3 / MU)
        ts = range(0.0, per/60; length=120)
        mm = 2π / (per/60)
        isls = Float64[]
        for da in 0:10:180
            r2, c2, s2 = deg2rad(Float64(da)), cos(deg2rad(Float64(da))), sin(deg2rad(Float64(da)))
            total, npairs = 0.0, 0
            for t in ts
                for m0 in mas
                    th = deg2rad(m0) + mm*t; xo=ro*cos(th); yo=ro*sin(th)
                    a1 = (xo, yo*si)
                    a2 = (c2*xo - s2*yo*ci, s2*xo + c2*yo*ci)
                    for m02 in mas
                        th2 = deg2rad(m02) + mm*t; xo2=ro*cos(th2); yo2=ro*sin(th2)
                        b1 = (xo2, yo2*si)
                        b2 = (c2*xo2 - s2*yo2*ci, s2*xo2 + c2*yo2*ci)
                        d = sqrt((a1[1]-b2[1])^2 + (a1[2]-b2[2])^2 + (0.0-b2[2])^2)
                        if d < exp.threshold_km; total += 1; end
                        npairs += 1
                    end
                end
            end
            push!(isls, round(total/npairs * exp.spp^2, digits=2))
        end
        results[alt] = isls
    end
    return results
end

register!(DeadZoneScan(), "dead_zone_scan")

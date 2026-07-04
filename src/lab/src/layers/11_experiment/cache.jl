# ===== 实验缓存 + 结果对比 API =====
# P2: produce_or_load（借鉴 DrWatson）
# P3: compare_results（通用对比）

using JSON
using Printf

export cached_experiment, compare_results

# ────────────────────────────────────────────────────────────
# P2: 实验缓存
# ────────────────────────────────────────────────────────────

_cache_dir() = joinpath("data", "cache")

"""
    config_hash(config) -> String

根据 ExperimentConfig 生成唯一 hash（用于缓存文件名）。
"""
function config_hash(config::ExperimentConfig)::String
    # 用关键字段生成 hash
    key = "$(config.constellation.T)_$(config.constellation.P)_$(config.constellation.F)_$(config.constellation.alt_km)_$(config.constellation.inc_deg)_$(length(config.tspan))_$(config.tspan[end])"
    return string(hash(key))
end

"""
    cached_experiment(config; force=false) -> ExperimentResult

带缓存的实验执行。相同参数的实验只跑一次。

```julia
# 第一次：跑仿真 + 缓存
result = cached_experiment(config)
# 第二次：从缓存读（秒级返回）
result2 = cached_experiment(config)
# 强制重跑
result3 = cached_experiment(config; force=true)
```
"""
function cached_experiment(config::ExperimentConfig; force::Bool=false)
    mkpath(_cache_dir())
    h = config_hash(config)
    path = joinpath(_cache_dir(), "$(h).json")

    # 缓存命中
    if !force && isfile(path)
        data = JSON.parsefile(path)
        @printf("[Cache] 命中: %s\n", path)
        return _dict_to_result(data, config)
    end

    # 缓存未命中：跑实验
    @printf("[Cache] 未命中，执行仿真...\n")
    result = run_experiment(config)

    # 保存到缓存
    open(path, "w") do io
        JSON.print(io, _result_to_dict(result), 2)
    end

    return result
end

# Result → Dict 序列化（处理 NaN）
function _result_to_dict(r::ExperimentResult)
    return Dict{String,Any}(
        "coverage_ratio" => isnan(r.coverage.coverage_ratio) ? 0.0 : r.coverage.coverage_ratio,
        "avg_latency_ms" => r.latency.avg_latency_ms,
        "max_latency_ms" => r.latency.max_latency_ms,
        "p95_latency_ms" => r.latency.p95_ms,
        "connectivity_ratio" => r.network.connectivity_ratio,
        "diameter_ms" => r.network.diameter,
        "fitness" => r.fitness,
        "duration_s" => r.duration_s,
    )
end

# Dict → Result 反序列化（从缓存重建）
function _dict_to_result(data::AbstractDict, config::ExperimentConfig)
    # 简化版：返回一个 Dict 而非完整的 ExperimentResult（避免类型重建复杂性）
    return data
end

# ────────────────────────────────────────────────────────────
# P3: 结果对比 API
# ────────────────────────────────────────────────────────────

"""
    compare_results(results::Dict{String,<:Any}) -> String

对比多个实验结果，返回 Markdown 格式对比表。

```julia
# 跑 3 个星座
r1 = cached_experiment(ExperimentConfig(name="iridium", constellation_params=Dict(:T=>66.0,:P=>6.0,:F=>2.0,:alt_km=>780.0,:inc_deg=>86.4), tspan=[0.0,60.0]))
r2 = cached_experiment(ExperimentConfig(name="starlink", constellation_params=Dict(:T=>158.0,:P=>72.0,:F=>1.0,:alt_km=>550.0,:inc_deg=>53.0), tspan=[0.0,60.0]))
# 对比
compare_results(Dict("Iridium" => r1, "Starlink" => r2))
```
"""
function compare_results(results::Dict{String,<:Any})::String
    isempty(results) && return "无结果可对比"

    # 统一提取指标（兼容 ExperimentResult 和 Dict）
    function get_metric(r, key, default=0.0)
        if r isa ExperimentResult
            key == :coverage && return isnan(r.coverage.coverage_ratio) ? 0.0 : r.coverage.coverage_ratio
            key == :avg_latency && return r.latency.avg_latency_ms
            key == :max_latency && return r.latency.max_latency_ms
            key == :p95 && return r.latency.p95_ms
            key == :connectivity && return r.network.connectivity_ratio
            key == :diameter && return r.network.diameter
            key == :fitness && return r.fitness
        elseif r isa AbstractDict
            # 缓存的 Dict 用不同 key 名
            key_map = Dict(:coverage => "coverage_ratio", :avg_latency => "avg_latency_ms",
                          :max_latency => "max_latency_ms", :p95 => "p95_latency_ms",
                          :connectivity => "connectivity_ratio", :diameter => "diameter_ms",
                          :fitness => "fitness")
            return get(r, get(key_map, key, string(key)), default)
        end
        return default
    end

    lines = String[]
    push!(lines, "| 星座 | 覆盖率 | avg时延(ms) | p95时延(ms) | 连通率 | 直径(ms) | fitness |")
    push!(lines, "|------|--------|-------------|-------------|--------|----------|---------|")

    for (name, r) in results
        @printf("| %-12s | %.1f%% | %11.1f | %11.1f | %6.1f%% | %8.1f | %7.3f |\n",
            name,
            get_metric(r, :coverage) * 100,
            get_metric(r, :avg_latency),
            get_metric(r, :p95),
            get_metric(r, :connectivity) * 100,
            get_metric(r, :diameter),
            get_metric(r, :fitness),
        )
        push!(lines, @sprintf("| %-12s | %.1f%% | %11.1f | %11.1f | %6.1f%% | %8.1f | %7.3f |",
            name,
            get_metric(r, :coverage) * 100,
            get_metric(r, :avg_latency),
            get_metric(r, :p95),
            get_metric(r, :connectivity) * 100,
            get_metric(r, :diameter),
            get_metric(r, :fitness),
        ))
    end

    table = join(lines, "\n")
    println("\n", table)
    return table
end

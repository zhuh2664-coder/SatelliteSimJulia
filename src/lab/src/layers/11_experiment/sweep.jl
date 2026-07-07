# ===== 参数扫描引擎 =====

export sweep, sweep_dict, sweep_ground_traffic

"""
    sweep(f, param::Symbol, values::Vector) -> Vector{Pair{T,Any}}

对参数 `param` 扫描 `values` 中每个值，调用 `f(; param => v)`，返回 (值, 结果) 列表。

# 示例
    results = sweep(cfg -> run_experiment(cfg), :alt_km, [400, 550, 800, 1200])
"""
function sweep(f::Function, param::Symbol, values::Vector)
    out = Pair{eltype(values),Any}[]
    for v in values
        result = try
            f(param => v)
        catch e
            @warn "sweep failed at $param=$v: $e"
            nothing
        end
        push!(out, v => result)
    end
    return out
end

"""
    sweep(f, params::Dict{Symbol,Vector}) -> Vector{Dict{Symbol,Any}}

多参数笛卡尔积扫描。
"""
function sweep_dict(f::Function, params::Dict{Symbol,Vector})
    keys_list = collect(keys(params))
    values_list = collect(values(params))
    combos = Iterators.product(values_list...)
    out = Dict{Symbol,Any}[]
    for combo in combos
        kw = Dict{Symbol,Any}(k => v for (k, v) in zip(keys_list, combo))
        result = try
            f(; kw...)
        catch e
            @warn "sweep failed at $kw: $e"
            nothing
        end
        push!(out, merge(kw, Dict(:result => result)))
    end
    return out
end

"""
    sweep_ground_traffic(scenario, param, values) -> Vector{NamedTuple}

外层参数扫描入口。`scenario(param => value)` 必须返回一次正式 ground traffic
`TrafficEvaluation`。本函数只负责扫描和摘要，不替代单次实验主入口。
"""
function sweep_ground_traffic(scenario::Function, param::Symbol, values::Vector)
    out = NamedTuple[]
    for value in values
        evaluation = try
            scenario(param => value)
        catch e
            @warn "ground traffic sweep failed at $param=$value: $e"
            nothing
        end
        summary = evaluation === nothing ? nothing : traffic_evaluation_summary(evaluation)
        push!(out, (
            param = param,
            value = value,
            evaluation = evaluation,
            summary = summary,
        ))
    end
    return out
end

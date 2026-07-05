# ===== AI tool resource guards =====
#
# 统一限制高成本工具调用。作为 pre_tool hook 注册，避免在每个工具里散落资源检查。

export ToolBudget, default_tool_budget, estimate_tool_cost, guard_tool_call,
       resource_guard_hook, register_default_tool_guards!

Base.@kwdef struct ToolBudget
    max_satellites::Int = 200
    max_steps::Int = 100
    max_duration_s::Float64 = 86400.0
    max_scan_values::Int = 20
    max_compare_constellations::Int = 10
    max_tle_sats::Int = 200
end

const _DEFAULT_TOOL_GUARDS_REGISTERED = Ref(false)

default_tool_budget() = ToolBudget()

function _walker_T(s::AbstractString)::Union{Int,Nothing}
    startswith(lowercase(strip(s)), "walker") || return nothing
    parts = split(strip(s[7:end]), r"[/\s]+")
    isempty(parts) && return nothing
    return parse(Int, parts[1])
end

function estimate_tool_cost(tool::String, args::AbstractDict)::Dict{String,Any}
    if tool == "run_simulation"
        constellation = String(get(args, "constellation", "walker 24/6/1"))
        return Dict{String,Any}(
            "steps" => Int(get(args, "steps", 2)),
            "duration_s" => Float64(get(args, "duration_s", 600)),
            "satellites" => _walker_T(constellation),
            "max_sats" => Int(get(args, "max_sats", 24)),
            "propagator" => String(get(args, "propagator", "fast")),
        )
    elseif tool == "scan_parameter"
        values = get(args, "values", Any[])
        return Dict{String,Any}("scan_values" => length(values))
    elseif tool == "compare_constellations"
        names = get(args, "constellations", Any[])
        return Dict{String,Any}("constellations" => length(names))
    end
    return Dict{String,Any}()
end

function guard_tool_call(tool::String, args::AbstractDict; budget::ToolBudget=default_tool_budget())::Tuple{Bool,String}
    cost = estimate_tool_cost(tool, args)

    if tool == "run_simulation"
        steps = get(cost, "steps", 2)
        steps <= budget.max_steps || return false, "steps=$steps exceeds max_steps=$(budget.max_steps)"

        duration = get(cost, "duration_s", 600.0)
        duration <= budget.max_duration_s || return false, "duration_s=$duration exceeds max_duration_s=$(budget.max_duration_s)"

        sats = get(cost, "satellites", nothing)
        sats === nothing || sats <= budget.max_satellites ||
            return false, "satellites=$sats exceeds max_satellites=$(budget.max_satellites)"

        if get(cost, "propagator", "fast") in ("tle_based", "sgp4")
            max_sats = get(cost, "max_sats", 24)
            max_sats <= budget.max_tle_sats ||
                return false, "max_sats=$max_sats exceeds max_tle_sats=$(budget.max_tle_sats)"
        end
    elseif tool == "scan_parameter"
        n = get(cost, "scan_values", 0)
        n <= budget.max_scan_values || return false, "scan values=$n exceeds max_scan_values=$(budget.max_scan_values)"
    elseif tool == "compare_constellations"
        n = get(cost, "constellations", 0)
        n <= budget.max_compare_constellations ||
            return false, "constellations=$n exceeds max_compare_constellations=$(budget.max_compare_constellations)"
    end

    return true, "ok"
end

function resource_guard_hook(ctx::PreToolCtx)
    ok, reason = guard_tool_call(ctx.tool, ctx.args)
    ok && return nothing
    return (:block, reason)
end

function register_default_tool_guards!()
    _DEFAULT_TOOL_GUARDS_REGISTERED[] && return nothing
    register_hook!(:pre_tool, resource_guard_hook)
    _DEFAULT_TOOL_GUARDS_REGISTERED[] = true
    return nothing
end

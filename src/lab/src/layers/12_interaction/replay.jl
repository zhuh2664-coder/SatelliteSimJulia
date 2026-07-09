# ===== Deterministic tool replay =====
#
# 从 trace/tool_replay_plan 重放工具调用。默认 dry_run=true，不执行工具；
# dry_run=false 时逐项调用 execute_tool(name,args)，并可校验 result_hash。

export ReplayStep, ReplayResult, replay_tools, replay_report

struct ReplayStep
    index::Int
    tool::String
    args::Dict{String,Any}
    expected_status::String
    status::String
    result::Union{Nothing,String}
    result_hash::Union{Nothing,String}
    matched_hash::Union{Nothing,Bool}
end

struct ReplayResult
    steps::Vector{ReplayStep}
    dry_run::Bool
end

function _normalize_replay_plan(plan)::Vector{Dict{String,Any}}
    if plan isa AgentTrace
        return [Dict{String,Any}(
            "tool" => get(e.payload, "tool", ""),
            "args" => get(e.payload, "args", Dict{String,Any}()),
            "status" => get(e.payload, "status", ""),
            "result_hash" => get(e.payload, "result_hash", nothing),
        ) for e in filter_trace(plan; event_type = "tool_call").events]
    end
    return [Dict{String,Any}(string(k) => v for (k, v) in item) for item in plan]
end

function _dict_string_any(d)::Dict{String,Any}
    return Dict{String,Any}(string(k) => v for (k, v) in d)
end

function replay_tools(plan; dry_run::Bool = true, verify_hash::Bool = false, agent = nothing)::ReplayResult
    items = _normalize_replay_plan(plan)
    steps = ReplayStep[]

    for (i, item) in enumerate(items)
        tool = String(get(item, "tool", ""))
        args = _dict_string_any(get(item, "args", Dict{String,Any}()))
        expected_status = String(get(item, "status", ""))
        expected_hash = get(item, "result_hash", nothing)

        result = nothing
        result_hash = nothing
        matched = nothing
        status = dry_run ? "planned" : "succeeded"

        if !dry_run
            result = agent === nothing ? execute_tool(tool, args) : execute_tool(tool, args, agent)
            result_hash = stable_digest(result)
            matched = verify_hash && expected_hash !== nothing ? result_hash == string(expected_hash) : nothing
            if verify_hash && matched === false
                status = "hash_mismatch"
            end
        end

        push!(steps, ReplayStep(i, tool, args, expected_status, status, result, result_hash, matched))
    end

    return ReplayResult(steps, dry_run)
end

function replay_report(result::ReplayResult)::Dict{String,Any}
    return Dict{String,Any}(
        "dry_run" => result.dry_run,
        "total" => length(result.steps),
        "mismatches" => count(s -> s.matched_hash === false, result.steps),
        "steps" => [Dict{String,Any}(
            "index" => s.index,
            "tool" => s.tool,
            "args" => s.args,
            "expected_status" => s.expected_status,
            "status" => s.status,
            "result_hash" => s.result_hash,
            "matched_hash" => s.matched_hash,
        ) for s in result.steps],
    )
end

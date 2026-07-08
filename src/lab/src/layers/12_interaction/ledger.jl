# ===== AI ledger =====
#
# AI 工具调用审计账本。不同于 memory：memory 给 prompt 用，ledger 给复现/审计用。

using SHA

export AI_LEDGER_VERSION, stable_json, stable_digest, ledger_path,
       record_ledger_event!, record_tool_ledger!, ledger_post_tool_hook,
       register_default_ledger_hooks!

const AI_LEDGER_VERSION = 1
const _DEFAULT_LEDGER_HOOKS_REGISTERED = Ref(false)

function _canonical(x)
    if x isa AbstractDict
        return Dict(string(k) => _canonical(v) for (k, v) in sort(collect(x); by = kv -> string(kv[1])))
    elseif x isa AbstractVector
        return [_canonical(v) for v in x]
    elseif x === nothing || x isa Number || x isa Bool || x isa AbstractString
        return x
    else
        return string(x)
    end
end

stable_json(x)::String = JSON.json(_canonical(x))
stable_digest(x)::String = "sha256:" * bytes2hex(sha256(stable_json(x)))

ledger_path(mem::SessionMemory)::String = joinpath(dirname(mem.transcript_path), "ledger.jsonl")

function _preview(s::Union{Nothing,String}; n::Int = 500)
    s === nothing && return nothing
    chars = collect(s)
    length(chars) <= n && return s
    return String(chars[1:n]) * "...(截断)"
end

function record_ledger_event!(mem::SessionMemory, event::Dict)::Dict
    e = Dict{String,Any}(event)
    e["ledger_version"] = AI_LEDGER_VERSION
    e["timestamp"] = get(e, "timestamp", Dates.format(now(), dateformat"yyyy-mm-ddTHH:MM:SS"))
    e["session_id"] = mem.session_id
    e["event_id"] = get(e, "event_id", stable_digest(e))

    path = ledger_path(mem)
    mkpath(dirname(path))
    open(path, "a") do io
        println(io, JSON.json(e))
    end
    return e
end

function record_tool_ledger!(agent, tool::String, args::AbstractDict;
                             status::String,
                             result::Union{Nothing,String}=nothing,
                             error::Union{Nothing,String}=nothing,
                             reason::Union{Nothing,String}=nothing,
                             started_at=nothing,
                             completed_at=nothing)::Dict
    agent === nothing && return Dict{String,Any}()
    hasproperty(agent, :memory) || return Dict{String,Any}()

    event = Dict{String,Any}(
        "event_type" => "tool_call",
        "tool" => tool,
        "args" => Dict(string(k) => v for (k, v) in args),
        "args_hash" => stable_digest(args),
        "status" => status,
        "result_hash" => result === nothing ? nothing : stable_digest(result),
        "result_preview" => _preview(result),
        "error" => error,
        "reason" => reason,
    )
    started_at === nothing || (event["started_at"] = string(started_at))
    completed_at === nothing || (event["completed_at"] = string(completed_at))
    return record_ledger_event!(agent.memory, event)
end

function ledger_post_tool_hook(ctx::PostToolCtx, value::AbstractString)
    record_tool_ledger!(ctx.agent, ctx.tool, ctx.args; status = "succeeded", result = ctx.result)
    return nothing
end

function register_default_ledger_hooks!()
    _DEFAULT_LEDGER_HOOKS_REGISTERED[] && return nothing
    register_hook!(:post_tool, ledger_post_tool_hook)
    _DEFAULT_LEDGER_HOOKS_REGISTERED[] = true
    return nothing
end

# ===== AI trace inspection =====
#
# 读取 ledger.jsonl，提供轻量可观测性与 replay 输入基础。
# 不执行工具，不改变仿真状态，只把审计账本整理成可过滤的 trace。

export TraceEvent, AgentTrace, load_agent_trace, filter_trace,
       trace_timeline, tool_replay_plan

struct TraceEvent
    event_id::String
    event_type::String
    timestamp::String
    session_id::String
    payload::Dict{String,Any}
end

struct AgentTrace
    session_id::String
    source_path::String
    events::Vector{TraceEvent}
end

function _trace_event(raw::AbstractDict)::TraceEvent
    payload = Dict{String,Any}(string(k) => v for (k, v) in raw)
    return TraceEvent(
        string(get(payload, "event_id", "")),
        string(get(payload, "event_type", "unknown")),
        string(get(payload, "timestamp", "")),
        string(get(payload, "session_id", "")),
        payload,
    )
end

function _load_trace_path(path::AbstractString; session_id::String = "")::AgentTrace
    events = TraceEvent[]
    if isfile(path)
        for line in readlines(path)
            isempty(strip(line)) && continue
            push!(events, _trace_event(JSON.parse(line)))
        end
    end
    sid = isempty(session_id) ? (isempty(events) ? "" : first(events).session_id) : session_id
    return AgentTrace(sid, String(path), events)
end

load_agent_trace(mem::SessionMemory)::AgentTrace =
    _load_trace_path(ledger_path(mem); session_id = mem.session_id)

function load_agent_trace(session_id::AbstractString; base_dir::AbstractString = joinpath("data", "sessions"))::AgentTrace
    path = joinpath(base_dir, String(session_id), "ledger.jsonl")
    return _load_trace_path(path; session_id = String(session_id))
end

function _criterion_match(value, criterion)::Bool
    criterion === nothing && return true
    value === nothing && return false
    if criterion isa AbstractVector || criterion isa Tuple || criterion isa Set
        return any(c -> string(value) == string(c), criterion)
    end
    return string(value) == string(criterion)
end

function filter_trace(trace::AgentTrace; event_type = nothing, status = nothing, tool = nothing)::AgentTrace
    events = [e for e in trace.events if
        _criterion_match(e.event_type, event_type) &&
        _criterion_match(get(e.payload, "status", nothing), status) &&
        _criterion_match(get(e.payload, "tool", nothing), tool)]
    return AgentTrace(trace.session_id, trace.source_path, events)
end

function _timeline_line(e::TraceEvent)::String
    parts = String[]
    isempty(e.timestamp) || push!(parts, e.timestamp)
    push!(parts, e.event_type)

    if haskey(e.payload, "tool")
        push!(parts, "tool=$(e.payload["tool"])")
    end
    if haskey(e.payload, "status")
        push!(parts, "status=$(e.payload["status"])")
    end
    if haskey(e.payload, "decision")
        push!(parts, "decision=$(e.payload["decision"])")
    end
    if haskey(e.payload, "from") || haskey(e.payload, "to")
        push!(parts, "route=$(get(e.payload, "from", "?"))->$(get(e.payload, "to", "?"))")
    end
    if haskey(e.payload, "reason") && e.payload["reason"] !== nothing
        push!(parts, "reason=$(e.payload["reason"])")
    end

    return join(parts, " | ")
end

function trace_timeline(trace::AgentTrace; max_events::Int = typemax(Int))::Vector{String}
    n = min(max_events, length(trace.events))
    return [_timeline_line(trace.events[i]) for i in 1:n]
end

function tool_replay_plan(trace::AgentTrace)::Vector{Dict{String,Any}}
    tool_events = filter_trace(trace; event_type = "tool_call").events
    return [Dict{String,Any}(
        "tool" => get(e.payload, "tool", ""),
        "args" => get(e.payload, "args", Dict{String,Any}()),
        "status" => get(e.payload, "status", ""),
        "args_hash" => get(e.payload, "args_hash", ""),
    ) for e in tool_events]
end

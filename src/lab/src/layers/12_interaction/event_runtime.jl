# ===== AI event runtime =====
#
# AutoGen-inspired lightweight event runtime. It adds publish/subscribe semantics
# inside SatelliteSimJulia without depending on AutoGen or Python.

export AIEvent, AIRuntime, subscribe!, publish!, emit_event!, run_event_loop!,
       runtime_state, load_runtime_state!, event_matches

struct AIEvent
    id::String
    source::String
    type::String
    subject::String
    time::DateTime
    data::Dict{String,Any}
end

mutable struct AIRuntime
    session_id::String
    memory::SessionMemory
    subscriptions::Dict{String,Vector{Function}}
    queue::Vector{AIEvent}
    handled::Int
end

function AIRuntime(; session_id::String = "ai_runtime_default")
    return AIRuntime(session_id, SessionMemory(session_id = session_id), Dict{String,Vector{Function}}(), AIEvent[], 0)
end

function _event_id()::String
    return "evt_" * bytes2hex(rand(UInt8, 8))
end

function _event_to_dict(event::AIEvent)::Dict{String,Any}
    return Dict{String,Any}(
        "id" => event.id,
        "source" => event.source,
        "type" => event.type,
        "subject" => event.subject,
        "time" => Dates.format(event.time, dateformat"yyyy-mm-ddTHH:MM:SS"),
        "data" => event.data,
    )
end

function _event_from_dict(d::AbstractDict)::AIEvent
    return AIEvent(
        String(get(d, "id", _event_id())),
        String(get(d, "source", "")),
        String(get(d, "type", "")),
        String(get(d, "subject", "")),
        DateTime(String(get(d, "time", "1970-01-01T00:00:00")), dateformat"yyyy-mm-ddTHH:MM:SS"),
        Dict{String,Any}(string(k) => v for (k, v) in get(d, "data", Dict{String,Any}())),
    )
end

function event_matches(pattern::AbstractString, event_type::AbstractString)::Bool
    p = String(pattern)
    t = String(event_type)
    p == "*" && return true
    p == t && return true
    if endswith(p, ".*")
        prefix = p[1:end-1]
        return startswith(t, prefix)
    end
    return false
end

function subscribe!(runtime::AIRuntime, pattern::AbstractString, handler::Function)
    push!(get!(runtime.subscriptions, String(pattern), Function[]), handler)
    return handler
end

subscribe!(handler::Function, runtime::AIRuntime, pattern::AbstractString) =
    subscribe!(runtime, pattern, handler)

function publish!(runtime::AIRuntime, event::AIEvent; record::Bool = true)::AIEvent
    push!(runtime.queue, event)
    if record
        record_ledger_event!(runtime.memory, Dict{String,Any}(
            "event_type" => "ai_runtime_event_published",
            "event_id" => event.id,
            "source" => event.source,
            "type" => event.type,
            "subject" => event.subject,
            "data" => event.data,
        ))
    end
    return event
end

function emit_event!(runtime::AIRuntime; source::String, type::String,
                     subject::String = "", data::Dict{String,Any} = Dict{String,Any}())::AIEvent
    return publish!(runtime, AIEvent(_event_id(), source, type, subject, now(), data))
end

function _publish_handler_return!(runtime::AIRuntime, ret)
    ret === nothing && return nothing
    if ret isa AIEvent
        publish!(runtime, ret)
    elseif ret isa AbstractVector
        for item in ret
            item isa AIEvent && publish!(runtime, item)
        end
    end
    return nothing
end

function run_event_loop!(runtime::AIRuntime; max_events::Int = typemax(Int))::Int
    processed = 0
    while !isempty(runtime.queue) && processed < max_events
        event = popfirst!(runtime.queue)
        for (pattern, handlers) in runtime.subscriptions
            event_matches(pattern, event.type) || continue
            for handler in handlers
                _publish_handler_return!(runtime, handler(event, runtime))
            end
        end
        runtime.handled += 1
        processed += 1
        record_ledger_event!(runtime.memory, Dict{String,Any}(
            "event_type" => "ai_runtime_event_handled",
            "event_id" => event.id,
            "source" => event.source,
            "type" => event.type,
            "subject" => event.subject,
        ))
    end
    return processed
end

function runtime_state(runtime::AIRuntime)::Dict{String,Any}
    return Dict{String,Any}(
        "session_id" => runtime.session_id,
        "queue" => [_event_to_dict(e) for e in runtime.queue],
        "handled" => runtime.handled,
        "subscriptions" => sort(collect(keys(runtime.subscriptions))),
    )
end

function load_runtime_state!(runtime::AIRuntime, state::AbstractDict)::AIRuntime
    empty!(runtime.queue)
    for item in get(state, "queue", Any[])
        push!(runtime.queue, _event_from_dict(item))
    end
    runtime.handled = Int(get(state, "handled", 0))
    return runtime
end

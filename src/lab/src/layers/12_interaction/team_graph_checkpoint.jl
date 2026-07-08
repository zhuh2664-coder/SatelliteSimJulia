# ===== Team graph checkpoints =====
#
# TeamGraph 的轻量持久化状态。用于中断后审计/恢复输入状态，
# 不重放 LLM，也不执行工具。

export team_graph_checkpoint_path, team_state_to_dict, team_state_from_dict,
       save_team_graph_checkpoint!, load_team_graph_checkpoint, checkpoint_summary

function team_graph_checkpoint_path(team::AgentTeam)::String
    return joinpath(dirname(team.shared_memory.transcript_path), "team_graph_checkpoint.json")
end

function _team_message_to_dict(msg::TeamMessage)::Dict{String,Any}
    return Dict{String,Any}(
        "from" => msg.from,
        "to" => msg.to,
        "role" => string(msg.role),
        "content" => msg.content,
        "timestamp" => Dates.format(msg.timestamp, dateformat"yyyy-mm-ddTHH:MM:SS"),
    )
end

function _team_message_from_dict(d::AbstractDict)::TeamMessage
    ts = DateTime(String(get(d, "timestamp", "1970-01-01T00:00:00")), dateformat"yyyy-mm-ddTHH:MM:SS")
    return TeamMessage(
        String(get(d, "from", "")),
        String(get(d, "to", "")),
        Symbol(String(get(d, "role", "unknown"))),
        String(get(d, "content", "")),
        ts,
    )
end

function team_state_to_dict(state::TeamState)::Dict{String,Any}
    return Dict{String,Any}(
        "user_input" => state.user_input,
        "transcript" => [_team_message_to_dict(m) for m in state.transcript],
        "artifacts" => state.artifacts,
        "current_node" => state.current_node,
        "step" => state.step,
        "status" => string(state.status),
    )
end

function team_state_from_dict(d::AbstractDict)::TeamState
    transcript = TeamMessage[]
    for item in get(d, "transcript", Any[])
        push!(transcript, _team_message_from_dict(item))
    end
    artifacts = Dict{String,Any}()
    for (k, v) in get(d, "artifacts", Dict{String,Any}())
        artifacts[string(k)] = v
    end
    return TeamState(
        String(get(d, "user_input", "")),
        transcript,
        artifacts,
        String(get(d, "current_node", "")),
        Int(get(d, "step", 0)),
        Symbol(String(get(d, "status", "running"))),
    )
end

function save_team_graph_checkpoint!(team::AgentTeam, state::TeamState;
                                     path::String = team_graph_checkpoint_path(team))::String
    mkpath(dirname(path))
    open(path, "w") do io
        JSON.print(io, team_state_to_dict(state))
    end
    record_ledger_event!(team.shared_memory, Dict{String,Any}(
        "event_type" => "team_graph_checkpoint",
        "path" => path,
        "step" => state.step,
        "current_node" => state.current_node,
        "status" => string(state.status),
    ))
    return path
end

function load_team_graph_checkpoint(path::AbstractString)::TeamState
    return team_state_from_dict(JSON.parsefile(path))
end

function checkpoint_summary(state::TeamState)::Dict{String,Any}
    return Dict{String,Any}(
        "user_input" => state.user_input,
        "step" => state.step,
        "status" => string(state.status),
        "current_node" => state.current_node,
        "messages" => length(state.transcript),
        "last_agent" => isempty(state.transcript) ? nothing : last(state.transcript).from,
    )
end

checkpoint_summary(path::AbstractString)::Dict{String,Any} =
    checkpoint_summary(load_team_graph_checkpoint(path))

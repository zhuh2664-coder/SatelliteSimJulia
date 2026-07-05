# ===== AI run control plane =====
#
# 产品级运行实体：把 agent/team_graph 执行、trace、checkpoint、artifacts
# 收敛成一个可查询的 AIRun。第一版为 in-process 同步执行，后续可替换为 worker。

export AIRunConfig, AIRunStatus, AIRunResult,
       start_ai_run, get_ai_run_status, get_ai_run_result, list_ai_runs,
       clear_ai_runs!

Base.@kwdef struct AIRunConfig
    id::String = "airun_$(rand(UInt))"
    user_input::String
    mode::Symbol = :team_graph              # :agent | :team_graph
    session_id::String = id
    checkpoint::Bool = true
    graph::Any = nothing
end

mutable struct AIRunStatus
    id::String
    session_id::String
    mode::Symbol
    state::Symbol                           # :queued | :running | :completed | :failed
    started_at::DateTime
    completed_at::Union{DateTime,Nothing}
    error::Union{String,Nothing}
end

struct AIRunResult
    id::String
    session_id::String
    mode::Symbol
    final_answer::String
    trace::AgentTrace
    checkpoint_summary::Dict{String,Any}
    artifacts::Dict{String,Any}
end

const AI_RUN_STATUSES = Dict{String,AIRunStatus}()
const AI_RUN_RESULTS = Dict{String,AIRunResult}()

function clear_ai_runs!()
    empty!(AI_RUN_STATUSES)
    empty!(AI_RUN_RESULTS)
    return nothing
end

function _ai_run_checkpoint_summary(session_id::String)::Dict{String,Any}
    path = joinpath("data", "sessions", session_id, "team_graph_checkpoint.json")
    isfile(path) || return Dict{String,Any}()
    return checkpoint_summary(path)
end

function _start_ai_run_status(config::AIRunConfig)::AIRunStatus
    status = AIRunStatus(config.id, config.session_id, config.mode, :running, now(), nothing, nothing)
    AI_RUN_STATUSES[config.id] = status
    record_ledger_event!(SessionMemory(session_id = config.session_id), Dict{String,Any}(
        "event_type" => "ai_run_started",
        "run_id" => config.id,
        "mode" => string(config.mode),
        "checkpoint" => config.checkpoint,
    ))
    return status
end

function _complete_ai_run!(status::AIRunStatus, result::AIRunResult)
    status.state = :completed
    status.completed_at = now()
    record_ledger_event!(SessionMemory(session_id = status.session_id), Dict{String,Any}(
        "event_type" => "ai_run_completed",
        "run_id" => status.id,
        "mode" => string(status.mode),
    ))
    completed = AIRunResult(result.id, result.session_id, result.mode, result.final_answer,
        load_agent_trace(result.session_id), result.checkpoint_summary, result.artifacts)
    AI_RUN_RESULTS[status.id] = completed
    return completed
end

function _fail_ai_run!(status::AIRunStatus, err)
    status.state = :failed
    status.completed_at = now()
    status.error = sprint(showerror, err)
    record_ledger_event!(SessionMemory(session_id = status.session_id), Dict{String,Any}(
        "event_type" => "ai_run_failed",
        "run_id" => status.id,
        "mode" => string(status.mode),
        "error" => status.error,
    ))
    return status
end

function start_ai_run(provider::AbstractLLMProvider, config::AIRunConfig)::AIRunResult
    status = _start_ai_run_status(config)
    try
        if config.mode == :agent
            agent = SimAgent(provider; session_id = config.session_id)
            final_answer = run_agent(agent, config.user_input)
            trace = load_agent_trace(agent.memory)
            result = AIRunResult(config.id, config.session_id, config.mode, final_answer,
                trace, Dict{String,Any}(), Dict{String,Any}())
            return _complete_ai_run!(status, result)
        elseif config.mode == :team_graph
            team = AgentTeam(provider; session_id = config.session_id)
            graph = config.graph === nothing ? default_team_graph() : config.graph
            graph_result = run_team_graph(team, graph, config.user_input; checkpoint = config.checkpoint)
            trace = load_agent_trace(team.shared_memory)
            result = AIRunResult(config.id, config.session_id, config.mode, graph_result.final_answer,
                trace, _ai_run_checkpoint_summary(config.session_id), graph_result.state.artifacts)
            return _complete_ai_run!(status, result)
        else
            error("unknown AI run mode: $(config.mode)")
        end
    catch e
        _fail_ai_run!(status, e)
        rethrow()
    end
end

function get_ai_run_status(id::AbstractString)::AIRunStatus
    haskey(AI_RUN_STATUSES, String(id)) || error("AI run not found: $id")
    return AI_RUN_STATUSES[String(id)]
end

function get_ai_run_result(id::AbstractString)::AIRunResult
    haskey(AI_RUN_RESULTS, String(id)) || error("AI run result not found or not completed: $id")
    return AI_RUN_RESULTS[String(id)]
end

list_ai_runs()::Vector{AIRunStatus} = [AI_RUN_STATUSES[id] for id in sort(collect(keys(AI_RUN_STATUSES)))]

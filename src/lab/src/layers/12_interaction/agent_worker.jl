# ===== Agent worker protocol =====
#
# AutoGen Agent Worker Protocol 风格的最小进程内骨架：worker 注册 agent type，
# service 负责按 (namespace, name) 路由，worker 首次收到请求时懒激活 agent。

export AgentId, AgentEvent, AgentRpcRequest, AgentRpcResponse,
       AgentWorker, AgentWorkerService, AgentDispatchResult,
       register_agent_type!, register_worker!, dispatch_agent!, dispatch_event!, dispatch_rpc!,
       supported_agent_types, active_agent_ids

struct AgentId
    namespace::String
    name::String
end

struct AgentEvent
    sender::AgentId
    recipient::AgentId
    content::String
end

struct AgentRpcRequest
    id::String
    sender::AgentId
    recipient::AgentId
    content::String
end

struct AgentRpcResponse
    id::String
    sender::AgentId
    recipient::AgentId
    content::String
    error::Union{String,Nothing}
end

struct AgentDispatchResult
    agent_id::AgentId
    worker_id::String
    content::String
    activated::Bool
end

mutable struct AgentWorker
    id::String
    provider::AbstractLLMProvider
    factories::Dict{String,Function}
    active::Dict{AgentId,SimAgent}
end

mutable struct AgentWorkerService
    workers::Dict{String,AgentWorker}
    placement::Dict{String,Vector{String}}
    directory::Dict{AgentId,String}
end

AgentWorker(id::AbstractString, provider::AbstractLLMProvider) =
    AgentWorker(String(id), provider, Dict{String,Function}(), Dict{AgentId,SimAgent}())

AgentWorkerService() =
    AgentWorkerService(Dict{String,AgentWorker}(), Dict{String,Vector{String}}(), Dict{AgentId,String}())

supported_agent_types(worker::AgentWorker) = sort(collect(keys(worker.factories)))
active_agent_ids(worker::AgentWorker) = collect(keys(worker.active))

function _agent_session_id(prefix::AbstractString, agent_id::AgentId)::String
    return "$(prefix)_$(agent_id.namespace)_$(agent_id.name)"
end

function register_agent_type!(worker::AgentWorker, name::AbstractString;
                              instruction::AbstractString = "",
                              tool_allowlist::Vector{String} = String[],
                              session_prefix::AbstractString = worker.id)
    agent_name = String(name)
    worker.factories[agent_name] = function (agent_id::AgentId)
        agent = SimAgent(worker.provider;
            session_goal = String(instruction),
            session_id = _agent_session_id(session_prefix, agent_id),
        )
        isempty(tool_allowlist) || (agent.tools = _filter_tools(agent.tools, tool_allowlist))
        return agent
    end
    return worker
end

function register_worker!(service::AgentWorkerService, worker::AgentWorker)
    service.workers[worker.id] = worker
    for name in supported_agent_types(worker)
        ids = get!(service.placement, name, String[])
        worker.id in ids || push!(ids, worker.id)
    end
    return service
end

function _activate_agent!(worker::AgentWorker, agent_id::AgentId)::Tuple{SimAgent,Bool}
    if haskey(worker.active, agent_id)
        return worker.active[agent_id], false
    end
    factory = get(worker.factories, agent_id.name, nothing)
    factory === nothing && error("worker $(worker.id) does not support agent type: $(agent_id.name)")
    agent = factory(agent_id)
    worker.active[agent_id] = agent
    return agent, true
end

function dispatch_agent!(worker::AgentWorker, agent_id::AgentId, input::AbstractString)::AgentDispatchResult
    agent, activated = _activate_agent!(worker, agent_id)
    content = run_agent(agent, String(input))
    return AgentDispatchResult(agent_id, worker.id, content, activated)
end

function _select_worker(service::AgentWorkerService, agent_id::AgentId)::AgentWorker
    if haskey(service.directory, agent_id)
        return service.workers[service.directory[agent_id]]
    end
    worker_ids = get(service.placement, agent_id.name, String[])
    isempty(worker_ids) && error("no worker registered for agent type: $(agent_id.name)")
    worker_id = first(worker_ids)
    service.directory[agent_id] = worker_id
    return service.workers[worker_id]
end

function dispatch_agent!(service::AgentWorkerService, agent_id::AgentId, input::AbstractString)::AgentDispatchResult
    worker = _select_worker(service, agent_id)
    return dispatch_agent!(worker, agent_id, input)
end

function dispatch_event!(worker::AgentWorker, event::AgentEvent)::Nothing
    dispatch_agent!(worker, event.recipient, event.content)
    return nothing
end

function dispatch_event!(service::AgentWorkerService, event::AgentEvent)::Nothing
    worker = _select_worker(service, event.recipient)
    dispatch_event!(worker, event)
    return nothing
end

function dispatch_rpc!(worker::AgentWorker, request::AgentRpcRequest)::AgentRpcResponse
    try
        result = dispatch_agent!(worker, request.recipient, request.content)
        return AgentRpcResponse(request.id, request.recipient, request.sender, result.content, nothing)
    catch err
        return AgentRpcResponse(request.id, request.recipient, request.sender, "", sprint(showerror, err))
    end
end

function dispatch_rpc!(service::AgentWorkerService, request::AgentRpcRequest)::AgentRpcResponse
    try
        worker = _select_worker(service, request.recipient)
        return dispatch_rpc!(worker, request)
    catch err
        return AgentRpcResponse(request.id, request.recipient, request.sender, "", sprint(showerror, err))
    end
end

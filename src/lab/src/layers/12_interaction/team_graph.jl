# ===== Team graph orchestration =====
#
# LangGraph 风格的轻量状态图执行器。复用 AgentTeam/SimAgent/tool guards/ledger，
# 只增强编排能力，不引入新的仿真逻辑。

export TeamNode, TeamState, TeamGraph, TeamGraphResult,
       default_team_graph, run_team_graph, resume_team_graph

struct TeamNode
    id::String
    agent_id::String
    next::Union{String,Nothing}
    router::Union{Function,Nothing}
end

mutable struct TeamState
    user_input::String
    transcript::Vector{TeamMessage}
    artifacts::Dict{String,Any}
    current_node::String
    step::Int
    status::Symbol
end

struct TeamGraph
    nodes::Dict{String,TeamNode}
    start::String
    max_steps::Int
end

struct TeamGraphResult
    final_answer::String
    state::TeamState
    transcript::Vector{TeamMessage}
end

function _reviewer_router(output::AbstractString, state::TeamState)::Union{String,Nothing}
    text = lowercase(String(output))
    if occursin("需要返工", output) || occursin("返工", output) ||
       occursin("revise", text) || occursin("revision", text)
        return "runner"
    end
    return nothing
end

function default_team_graph(; max_steps::Int = 8)::TeamGraph
    nodes = Dict{String,TeamNode}(
        "planner" => TeamNode("planner", "planner", "runner", nothing),
        "runner" => TeamNode("runner", "runner", "reviewer", nothing),
        "reviewer" => TeamNode("reviewer", "reviewer", nothing, _reviewer_router),
    )
    return TeamGraph(nodes, "planner", max_steps)
end

function _record_team_step!(team::AgentTeam, state::TeamState, node_id::String, event_type::String; kwargs...)
    event = Dict{String,Any}(
        "event_type" => event_type,
        "node" => node_id,
        "step" => state.step,
        "status" => string(state.status),
    )
    for (k, v) in kwargs
        event[string(k)] = v
    end
    record_ledger_event!(team.shared_memory, event)
    return event
end

function _team_graph_input(spec::AgentSpec, state::TeamState)::String
    io = IOBuffer()
    println(io, "角色指令: ", spec.instruction)
    println(io, "用户原始需求: ", state.user_input)
    if !isempty(state.transcript)
        println(io, "\n状态图前序输出:")
        for msg in state.transcript
            println(io, "- ", msg.from, "(", msg.role, "): ", msg.content)
        end
    end
    if !isempty(state.artifacts)
        println(io, "\n共享 artifacts keys: ", join(sort(collect(keys(state.artifacts))), ", "))
        println(io, "共享 artifacts: ", JSON.json(state.artifacts))
    end
    println(io, "\n如需给后续节点传递结构化产物，可单独输出一行：ARTIFACT <key> <json>。")
    println(io, "请按你的角色完成当前节点任务。")
    return String(take!(io))
end

function _route_next(node::TeamNode, output::AbstractString, state::TeamState)::Union{String,Nothing}
    if node.router !== nothing
        routed = node.router(output, state)
        routed === nothing || return routed
    end
    return node.next
end

function _maybe_checkpoint_team_graph!(team::AgentTeam, state::TeamState, checkpoint::Bool, checkpoint_path)
    checkpoint || return nothing
    isdefined(@__MODULE__, :save_team_graph_checkpoint!) || return nothing
    checkpoint_path === nothing ? save_team_graph_checkpoint!(team, state) :
                                  save_team_graph_checkpoint!(team, state; path = checkpoint_path)
    return nothing
end

function _run_team_graph_loop!(team::AgentTeam, graph::TeamGraph, state::TeamState;
                               checkpoint::Bool = false,
                               checkpoint_path::Union{String,Nothing} = nothing)::TeamGraphResult
    state.status = :running
    while state.current_node !== nothing && state.current_node != "" && state.step < graph.max_steps
        state.step += 1
        node = graph.nodes[state.current_node]
        spec = first(s for s in team.specs if s.id == node.agent_id)
        agent = team.agents[node.agent_id]

        _record_team_step!(team, state, node.id, "team_step_started"; agent = node.agent_id)
        input = _team_graph_input(spec, state)
        reply = run_agent(agent, input)
        artifact_keys = isdefined(@__MODULE__, :extract_team_artifacts!) ?
                        extract_team_artifacts!(state, reply) : String[]
        isempty(artifact_keys) || _record_team_step!(team, state, node.id, "team_artifacts_updated";
            keys = artifact_keys)

        next_node = _route_next(node, reply, state)
        to = next_node === nothing ? "user" : graph.nodes[next_node].agent_id
        msg = TeamMessage(node.agent_id, to, spec.role, reply, now())
        push!(state.transcript, msg)
        _record_team_message!(team, msg)
        _record_team_step!(team, state, node.id, "routing_decision";
            from = node.id,
            to = next_node === nothing ? "final" : next_node)

        state.current_node = next_node === nothing ? "" : next_node
        _maybe_checkpoint_team_graph!(team, state, checkpoint, checkpoint_path)
        next_node === nothing && break
    end

    state.status = state.step >= graph.max_steps && state.current_node != "" ? :max_steps_reached : :completed
    _maybe_checkpoint_team_graph!(team, state, checkpoint, checkpoint_path)
    record_ledger_event!(team.shared_memory, Dict{String,Any}(
        "event_type" => "team_graph_finished",
        "status" => string(state.status),
        "steps" => state.step,
    ))

    final_answer = isempty(state.transcript) ? "" : last(state.transcript).content
    return TeamGraphResult(final_answer, state, state.transcript)
end

function run_team_graph(team::AgentTeam, graph::TeamGraph, user_input::String;
                        checkpoint::Bool = false,
                        checkpoint_path::Union{String,Nothing} = nothing)::TeamGraphResult
    state = TeamState(user_input, TeamMessage[], Dict{String,Any}(), graph.start, 0, :running)
    record_ledger_event!(team.shared_memory, Dict{String,Any}(
        "event_type" => "team_graph_started",
        "start" => graph.start,
        "max_steps" => graph.max_steps,
    ))
    return _run_team_graph_loop!(team, graph, state;
        checkpoint = checkpoint,
        checkpoint_path = checkpoint_path,
    )
end

function resume_team_graph(team::AgentTeam, graph::TeamGraph, state::TeamState;
                           checkpoint::Bool = false,
                           checkpoint_path::Union{String,Nothing} = nothing)::TeamGraphResult
    record_ledger_event!(team.shared_memory, Dict{String,Any}(
        "event_type" => "team_graph_resumed",
        "current_node" => state.current_node,
        "step" => state.step,
        "max_steps" => graph.max_steps,
    ))
    return _run_team_graph_loop!(team, graph, state;
        checkpoint = checkpoint,
        checkpoint_path = checkpoint_path,
    )
end

function resume_team_graph(team::AgentTeam, graph::TeamGraph, checkpoint_path::AbstractString;
                           checkpoint::Bool = false)::TeamGraphResult
    isdefined(@__MODULE__, :load_team_graph_checkpoint) || error("team graph checkpoint support is not loaded")
    state = load_team_graph_checkpoint(checkpoint_path)
    return resume_team_graph(team, graph, state;
        checkpoint = checkpoint,
        checkpoint_path = String(checkpoint_path),
    )
end

function run_team_graph(provider::AbstractLLMProvider, user_input::String;
                        session_id::String = "team_default",
                        specs::Vector{AgentSpec} = default_agent_specs(),
                        graph::TeamGraph = default_team_graph(),
                        checkpoint::Bool = false,
                        checkpoint_path::Union{String,Nothing} = nothing)::TeamGraphResult
    team = AgentTeam(provider; session_id = session_id, specs = specs)
    return run_team_graph(team, graph, user_input;
        checkpoint = checkpoint,
        checkpoint_path = checkpoint_path,
    )
end

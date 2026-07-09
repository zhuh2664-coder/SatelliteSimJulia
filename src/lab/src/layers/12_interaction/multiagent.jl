# ===== Multi-agent orchestration =====
#
# AutoGen/CrewAI/LangGraph 风格的轻量顺序多智能体编排层。
# 只组合现有 SimAgent / tool registry / hooks / ledger，不新增物理或网络逻辑。

export AgentSpec, TeamMessage, TeamResult, AgentTeam,
       default_agent_specs, run_team

struct AgentSpec
    id::String
    role::Symbol
    instruction::String
    tool_allowlist::Vector{String}
end

struct TeamMessage
    from::String
    to::String
    role::Symbol
    content::String
    timestamp::DateTime
end

struct TeamResult
    final_answer::String
    transcript::Vector{TeamMessage}
end

mutable struct AgentTeam
    provider::AbstractLLMProvider
    specs::Vector{AgentSpec}
    agents::Dict{String,SimAgent}
    shared_memory::SessionMemory
    max_rounds::Int
end

function default_agent_specs()::Vector{AgentSpec}
    return [
        AgentSpec(
            "planner",
            :planner,
            "你是实验规划智能体。先理解用户目标，必要时调用 goal/planner 工具，输出简洁实验计划，不直接执行高成本实验。",
            ["list_available", "list_goals", "describe_goal", "plan_study"],
        ),
        AgentSpec(
            "runner",
            :runner,
            "你是实验执行智能体。根据 planner 的计划执行小规模仿真或扫描，并返回结构化结果摘要。",
            ["run_simulation", "scan_parameter", "compare_constellations", "run_study_plan", "list_available"],
        ),
        AgentSpec(
            "reviewer",
            :reviewer,
            "你是结果审查智能体。审查 runner 的结果是否可信，指出限制，并给出最终中文结论。不要重复执行高成本实验。",
            ["list_available"],
        ),
    ]
end

function _filter_tools(tools::Vector{Dict}, allowlist::Vector{String})::Vector{Dict}
    allowed = Set(allowlist)
    return [t for t in tools if get(t, "name", "") in allowed]
end

function AgentTeam(provider::AbstractLLMProvider;
                   session_id::String = "team_default",
                   specs::Vector{AgentSpec} = default_agent_specs(),
                   max_rounds::Int = length(specs))
    shared = SessionMemory(session_id = session_id)
    agents = Dict{String,SimAgent}()
    for spec in specs
        agent = SimAgent(provider;
            session_goal = spec.instruction,
            session_id = "$(session_id)_$(spec.id)",
        )
        agent.tools = _filter_tools(agent.tools, spec.tool_allowlist)
        agents[spec.id] = agent
    end
    return AgentTeam(provider, specs, agents, shared, max_rounds)
end

function _preview_content(s::AbstractString; n::Int = 500)
    chars = collect(String(s))
    length(chars) <= n && return String(s)
    return String(chars[1:n]) * "...(截断)"
end

function _record_team_message!(team::AgentTeam, msg::TeamMessage)
    record_ledger_event!(team.shared_memory, Dict{String,Any}(
        "event_type" => "agent_message",
        "from" => msg.from,
        "to" => msg.to,
        "role" => string(msg.role),
        "content_preview" => _preview_content(msg.content),
    ))
    return msg
end

function _team_input(spec::AgentSpec, user_input::String, prior::Vector{TeamMessage})::String
    io = IOBuffer()
    println(io, "角色指令: ", spec.instruction)
    println(io, "用户原始需求: ", user_input)
    if !isempty(prior)
        println(io, "\n前序智能体输出:")
        for msg in prior
            println(io, "- ", msg.from, "(", msg.role, "): ", msg.content)
        end
    end
    println(io, "\n请按你的角色完成下一步。")
    return String(take!(io))
end

function run_team(team::AgentTeam, user_input::String)::TeamResult
    transcript = TeamMessage[]
    n = min(team.max_rounds, length(team.specs))

    for i in 1:n
        spec = team.specs[i]
        agent = team.agents[spec.id]
        input = _team_input(spec, user_input, transcript)
        reply = run_agent(agent, input)
        to = i < n ? team.specs[i + 1].id : "user"
        msg = TeamMessage(spec.id, to, spec.role, reply, now())
        push!(transcript, msg)
        _record_team_message!(team, msg)
    end

    final_answer = isempty(transcript) ? "" : last(transcript).content
    return TeamResult(final_answer, transcript)
end

function run_team(provider::AbstractLLMProvider, user_input::String;
                  session_id::String = "team_default",
                  specs::Vector{AgentSpec} = default_agent_specs())::TeamResult
    team = AgentTeam(provider; session_id = session_id, specs = specs)
    return run_team(team, user_input)
end

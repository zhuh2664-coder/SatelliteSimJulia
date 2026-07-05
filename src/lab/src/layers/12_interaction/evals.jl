# ===== AI eval harness / regression benchmark =====
#
# 离线评测 Agent / TeamGraph 行为。默认用 MockProvider，避免测试依赖外部 LLM。

export AgentEvalCase, AgentEvalResult, AgentEvalSuiteResult,
       run_agent_eval, run_agent_eval_suite, eval_pass_rate, eval_report,
       run_ai_regression_benchmark

Base.@kwdef struct AgentEvalCase
    id::String
    input::String
    responses::Vector{AssistantMessage}
    expected_contains::Vector{String} = String[]
    expected_tools::Vector{String} = String[]
    mode::Symbol = :agent              # :agent | :team_graph
    graph::Any = nothing
end

struct AgentEvalResult
    id::String
    passed::Bool
    final_answer::String
    tool_calls::Vector{String}
    duration_ms::Float64
    failures::Vector{String}
end

struct AgentEvalSuiteResult
    results::Vector{AgentEvalResult}
    duration_ms::Float64
end

function _copy_responses(responses::Vector{AssistantMessage})::Vector{AssistantMessage}
    return [AssistantMessage(r.content, copy(r.tool_calls)) for r in responses]
end

function _assistant_tool_names(messages)::Vector{String}
    names = String[]
    for msg in messages
        get(msg, "role", "") == "assistant" || continue
        for tc in get(msg, "tool_calls", Any[])
            fn = get(tc, "function", Dict{String,Any}())
            haskey(fn, "name") && push!(names, String(fn["name"]))
        end
    end
    return names
end

function _team_tool_names(team::AgentTeam)::Vector{String}
    names = String[]
    for id in sort(collect(keys(team.agents)))
        append!(names, _assistant_tool_names(team.agents[id].messages))
    end
    return names
end

function _eval_failures(case::AgentEvalCase, final_answer::String, tool_calls::Vector{String})::Vector{String}
    failures = String[]
    for s in case.expected_contains
        occursin(s, final_answer) || push!(failures, "final answer missing: $s")
    end
    for tool in case.expected_tools
        tool in tool_calls || push!(failures, "tool not called: $tool")
    end
    return failures
end

function run_agent_eval(case::AgentEvalCase; session_id::String = "eval_$(case.id)_$(rand(UInt))")::AgentEvalResult
    started = time()
    provider = MockProvider(_copy_responses(case.responses))
    final_answer = ""
    tool_calls = String[]

    if case.mode == :agent
        agent = SimAgent(provider; session_id = session_id)
        final_answer = run_agent(agent, case.input)
        tool_calls = _assistant_tool_names(agent.messages)
    elseif case.mode == :team_graph
        team = AgentTeam(provider; session_id = session_id)
        graph = case.graph === nothing ? default_team_graph() : case.graph
        result = run_team_graph(team, graph, case.input)
        final_answer = result.final_answer
        tool_calls = _team_tool_names(team)
    else
        error("unknown eval mode: $(case.mode)")
    end

    duration_ms = (time() - started) * 1000
    failures = _eval_failures(case, final_answer, tool_calls)
    return AgentEvalResult(case.id, isempty(failures), final_answer, tool_calls, duration_ms, failures)
end

function run_agent_eval_suite(cases::Vector{AgentEvalCase}; session_prefix::String = "eval_suite")::AgentEvalSuiteResult
    started = time()
    results = AgentEvalResult[]
    for (i, case) in enumerate(cases)
        push!(results, run_agent_eval(case; session_id = "$(session_prefix)_$(i)_$(case.id)"))
    end
    return AgentEvalSuiteResult(results, (time() - started) * 1000)
end

eval_pass_rate(result::AgentEvalSuiteResult)::Float64 =
    isempty(result.results) ? 1.0 : count(r -> r.passed, result.results) / length(result.results)

function eval_report(result::AgentEvalSuiteResult)::Dict{String,Any}
    return Dict{String,Any}(
        "total" => length(result.results),
        "passed" => count(r -> r.passed, result.results),
        "pass_rate" => eval_pass_rate(result),
        "duration_ms" => round(result.duration_ms, digits = 3),
        "cases" => [Dict{String,Any}(
            "id" => r.id,
            "passed" => r.passed,
            "duration_ms" => round(r.duration_ms, digits = 3),
            "tool_calls" => r.tool_calls,
            "failures" => r.failures,
        ) for r in result.results],
    )
end

run_ai_regression_benchmark(cases::Vector{AgentEvalCase}; session_prefix::String = "ai_regression") =
    eval_report(run_agent_eval_suite(cases; session_prefix = session_prefix))

#!/usr/bin/env julia

# Product-grade AI orchestration benchmark.
# Deterministic by design: all LLM responses use MockProvider.

using JSON
using SatelliteSimLab

function _cleanup_session(session_id::AbstractString)
    for suffix in ("", "_planner", "_runner", "_reviewer")
        path = joinpath("data", "sessions", String(session_id) * suffix)
        isdir(path) && rm(path; recursive = true, force = true)
    end
    SatelliteSimLab.clear_hooks!()
end

function _benchmark_cases()
    return [
        AgentEvalCase(
            id = "agent-list-propagators",
            input = "列出可用传播器",
            responses = [
                AssistantMessage("", [
                    ToolCall("call_1", "list_available", Dict{String,Any}("what" => "propagators")),
                ]),
                AssistantMessage("可用传播器包括 fast/balanced/precise/tle_based", ToolCall[]),
            ],
            expected_contains = ["tle_based"],
            expected_tools = ["list_available"],
        ),
        AgentEvalCase(
            id = "team-linear-artifacts",
            input = "规划并执行一个结构化任务",
            responses = [
                AssistantMessage("计划完成\nARTIFACT plan {\"goal\":\"coverage\",\"constellation\":\"walker24\"}", ToolCall[]),
                AssistantMessage("执行完成\nARTIFACT result {\"coverage\":0.9}", ToolCall[]),
                AssistantMessage("最终结论：通过，coverage=0.9", ToolCall[]),
            ],
            expected_contains = ["coverage=0.9"],
            mode = :team_graph,
        ),
        AgentEvalCase(
            id = "team-revision-loop",
            input = "需要审查和返工的任务",
            responses = [
                AssistantMessage("计划完成", ToolCall[]),
                AssistantMessage("第一次执行结果", ToolCall[]),
                AssistantMessage("需要返工：补充结果", ToolCall[]),
                AssistantMessage("第二次执行完成", ToolCall[]),
                AssistantMessage("最终结论：通过", ToolCall[]),
            ],
            expected_contains = ["通过"],
            mode = :team_graph,
        ),
    ]
end

function _schema_permission_checks!()
    session_id = "bench_schema_permission_$(rand(UInt))"
    try
        agent = SimAgent(LLMProvider(; key = "dummy"); session_id = session_id)

        invalid = validate_tool_args("list_available", Dict{String,Any}("what" => "everything"))
        invalid.ok && error("schema validation failed to reject invalid enum")

        denied = SimAgent(
            LLMProvider(; key = "dummy");
            session_id = session_id * "_deny",
            permission_policy = ToolPermissionPolicy(rules = Dict("list_available" => :deny)),
        )
        out = execute_tool("list_available", Dict{String,Any}("what" => "all"), denied)
        occursin("permission denied", out) || error("permission deny did not block tool")

        ask = SimAgent(
            LLMProvider(; key = "dummy");
            session_id = session_id * "_ask",
            permission_policy = ToolPermissionPolicy(rules = Dict("list_available" => :ask)),
        )
        args = Dict{String,Any}("what" => "propagators")
        first = execute_tool("list_available", args, ask)
        occursin("human approval required", first) || error("HITL ask did not request approval")
        approve_tool_call!(ask, "list_available", args)
        second = execute_tool("list_available", args, ask)
        occursin("tle_based", second) || error("approved HITL tool did not execute")

        return true
    finally
        _cleanup_session(session_id)
        _cleanup_session(session_id * "_deny")
        _cleanup_session(session_id * "_ask")
    end
end

function _checkpoint_replay_checks!()
    session_id = "bench_checkpoint_replay_$(rand(UInt))"
    try
        provider = MockProvider([
            AssistantMessage("计划完成\nARTIFACT plan {\"goal\":\"coverage\"}", ToolCall[]),
            AssistantMessage("执行完成\nARTIFACT result {\"coverage\":0.8}", ToolCall[]),
            AssistantMessage("最终结论：恢复通过", ToolCall[]),
        ])
        team = AgentTeam(provider; session_id = session_id)
        first = run_team_graph(team, default_team_graph(; max_steps = 1), "checkpoint benchmark"; checkpoint = true)
        first.state.status == :max_steps_reached || error("checkpoint benchmark did not stop at max_steps")

        resumed = resume_team_graph(team, default_team_graph(; max_steps = 3), team_graph_checkpoint_path(team); checkpoint = true)
        resumed.state.status == :completed || error("resume benchmark did not complete")
        haskey(resumed.state.artifacts, "plan") || error("artifact not preserved through resume")

        original = execute_tool("list_available", Dict{String,Any}("what" => "propagators"))
        record_ledger_event!(team.shared_memory, Dict{String,Any}(
            "event_type" => "tool_call",
            "tool" => "list_available",
            "args" => Dict("what" => "propagators"),
            "status" => "succeeded",
            "result_hash" => stable_digest(original),
        ))
        trace = load_agent_trace(team.shared_memory)
        replay = replay_tools(trace; dry_run = false, verify_hash = true)
        any(s -> s.tool == "list_available" && s.matched_hash === true, replay.steps) ||
            error("deterministic replay hash check failed")

        return true
    finally
        _cleanup_session(session_id)
    end
end

function main()
    cases = _benchmark_cases()
    suite = run_agent_eval_suite(cases; session_prefix = "benchmark_ai")
    report = eval_report(suite)
    report["schema_permission_checks"] = _schema_permission_checks!()
    report["checkpoint_replay_checks"] = _checkpoint_replay_checks!()
    report["product_gate_passed"] = report["passed"] == report["total"] &&
                                     report["schema_permission_checks"] &&
                                     report["checkpoint_replay_checks"]

    println(JSON.json(report))
    report["product_gate_passed"] || exit(1)
end

main()

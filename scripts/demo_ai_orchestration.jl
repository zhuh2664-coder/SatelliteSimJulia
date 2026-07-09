#!/usr/bin/env julia

# One-command deterministic demo of the AI orchestration control plane.

using JSON
using SatelliteSimLab

function cleanup(session_id)
    for suffix in ("", "_planner", "_runner", "_reviewer")
        path = joinpath("data", "sessions", session_id * suffix)
        isdir(path) && rm(path; recursive = true, force = true)
    end
    SatelliteSimLab.clear_hooks!()
end

function main()
    session_id = "demo_ai_orchestration"
    cleanup(session_id)

    provider = MockProvider([
        AssistantMessage("计划完成\nARTIFACT plan {\"goal\":\"coverage\",\"constellation\":\"walker24\"}", ToolCall[]),
        AssistantMessage("执行完成\nARTIFACT result {\"coverage\":0.87,\"latency_ms\":16.2}", ToolCall[]),
        AssistantMessage("最终结论：结构化结果可信，coverage=0.87", ToolCall[]),
    ])
    team = AgentTeam(provider; session_id = session_id)

    println("# TeamGraph run with checkpoint")
    result = run_team_graph(team, default_team_graph(), "规划并执行 walker24 覆盖分析"; checkpoint = true)
    println("final_answer=", result.final_answer)
    println("artifacts=", JSON.json(result.state.artifacts))
    println("checkpoint=", team_graph_checkpoint_path(team))

    println("\n# Checkpoint summary")
    println(JSON.json(checkpoint_summary(team_graph_checkpoint_path(team))))

    tool_result = execute_tool("list_available", Dict{String,Any}("what" => "propagators"))
    record_ledger_event!(team.shared_memory, Dict{String,Any}(
        "event_type" => "tool_call",
        "tool" => "list_available",
        "args" => Dict("what" => "propagators"),
        "status" => "succeeded",
        "result_hash" => stable_digest(tool_result),
    ))

    println("\n# Trace timeline")
    trace = load_agent_trace(team.shared_memory)
    for line in trace_timeline(trace; max_events = 12)
        println(line)
    end

    println("\n# Deterministic replay dry-run")
    replay = replay_tools(trace; dry_run = true)
    println(JSON.json(replay_report(replay)))

    println("\n# Eval report")
    eval_case = AgentEvalCase(
        id = "demo-team-artifact",
        input = "demo",
        responses = [
            AssistantMessage("计划完成\nARTIFACT plan {\"goal\":\"coverage\"}", ToolCall[]),
            AssistantMessage("执行完成\nARTIFACT result {\"coverage\":0.87}", ToolCall[]),
            AssistantMessage("最终结论：coverage=0.87", ToolCall[]),
        ],
        expected_contains = ["coverage=0.87"],
        mode = :team_graph,
    )
    println(JSON.json(run_ai_regression_benchmark([eval_case]; session_prefix = "demo_eval")))
end

main()

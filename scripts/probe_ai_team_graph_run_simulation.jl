#!/usr/bin/env julia

using JSON
using Test
using SatelliteSimLab

function cleanup_team_sessions(session_id::String)
    for suffix in ("", "_planner", "_runner", "_reviewer")
        path = joinpath("data", "sessions", session_id * suffix)
        isdir(path) && rm(path; recursive=true, force=true)
    end
end

@testset "AI team graph runs simulation tool" begin
    session_id = "probe_ai_team_graph_run_simulation_$(rand(UInt))"

    try
        provider = MockProvider([
            AssistantMessage("计划：运行一个 6 颗星的小规模仿真，然后审查指标。", ToolCall[]),
            AssistantMessage("", [
                ToolCall(
                    "call_runner_sim",
                    "run_simulation",
                    Dict{String,Any}(
                        "constellation" => "walker 6/3/1",
                        "duration_s" => 60,
                        "steps" => 2,
                        "topology" => "minimal",
                        "propagator" => "fast",
                    ),
                ),
            ]),
            AssistantMessage(
                "执行完成：仿真工具返回 coverage_ratio、avg_latency_ms、connectivity_ratio。",
                ToolCall[],
            ),
            AssistantMessage("最终结论：通过。结果可信，但规模很小，只能作为 smoke。", ToolCall[]),
        ])

        team = AgentTeam(provider; session_id=session_id)
        result = run_team_graph(team, default_team_graph(), "用多智能体跑一个最小仿真实验")

        @test result.state.status == :completed
        @test [msg.from for msg in result.transcript] == ["planner", "runner", "reviewer"]
        @test occursin("最终结论", result.final_answer)

        runner_messages = team.agents["runner"].messages
        tool_messages = [msg for msg in runner_messages if get(msg, "role", "") == "tool"]
        @test length(tool_messages) == 1

        payload = JSON.parse(tool_messages[1]["content"]; allownan=true)
        @test haskey(payload, "coverage_ratio")
        @test haskey(payload, "avg_latency_ms")
        @test haskey(payload, "connectivity_ratio")
        @test payload["n_satellites"] == 6

        runner_ledger = ledger_path(team.agents["runner"].memory)
        @test isfile(runner_ledger)
        @test any(
            line -> occursin("\"event_type\":\"tool_call\"", line) &&
                    occursin("\"tool\":\"run_simulation\"", line) &&
                    occursin("\"status\":\"succeeded\"", line),
            readlines(runner_ledger),
        )
    finally
        cleanup_team_sessions(session_id)
        clear_hooks!()
    end
end

println("AI TEAM GRAPH RUN SIMULATION: ALL PASS")

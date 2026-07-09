#!/usr/bin/env julia

using JSON
using Test
using SatelliteSimCore
using SatelliteSimLab
using SatelliteSimNet

function cleanup_team_traffic_sessions(session_id::String)
    for suffix in ("", "_planner", "_runner", "_reviewer")
        path = joinpath("data", "sessions", session_id * suffix)
        isdir(path) && rm(path; recursive=true, force=true)
    end
end

function team_probe_subpoint_deg(positions::Array{Float64,3}, sat_id::Int)
    x, y, z = positions[sat_id, 1, 1], positions[sat_id, 1, 2], positions[sat_id, 1, 3]
    radius = sqrt(x * x + y * y + z * z)
    return (asind(z / radius), atan(y, x) * 180 / pi)
end

@testset "AI team graph runs traffic AON simulation" begin
    session_id = "probe_ai_team_graph_traffic_aon_$(rand(UInt))"

    seed = ExperimentConfig(
        constellation_params = Dict(:T => 48.0, :P => 8.0, :F => 1.0, :alt_km => 550.0, :inc_deg => 53.0),
        tspan = collect(range(0.0, 120.0; length = 3)),
        topology_strategy = GridPlusStrategy(),
    )
    _, positions = propagate_constellation_positions(seed)
    src_lat, src_lon = team_probe_subpoint_deg(positions, 1)
    dst_lat, dst_lon = team_probe_subpoint_deg(positions, 2)

    try
        provider = MockProvider([
            AssistantMessage("计划：运行一个带地面流量的 48 星 Walker 仿真，然后审查 AON 是否启动。", ToolCall[]),
            AssistantMessage("", [
                ToolCall(
                    "call_runner_traffic_sim",
                    "run_simulation",
                    Dict{String,Any}(
                        "constellation" => "walker 48/8/1",
                        "duration_s" => 120,
                        "steps" => 3,
                        "topology" => "balanced",
                        "propagator" => "fast",
                        "traffic" => "uniform",
                        "ground_stations" => [
                            Dict{String,Any}("id" => 1, "name" => "source", "lat" => src_lat, "lon" => src_lon, "alt_km" => 0.0),
                            Dict{String,Any}("id" => 2, "name" => "destination", "lat" => dst_lat, "lon" => dst_lon, "alt_km" => 0.0),
                        ],
                        "ground_pairs" => [[1, 2]],
                    ),
                ),
            ]),
            AssistantMessage("执行完成：traffic_evaluation_ran 为 true，AON bridge 已启动。", ToolCall[]),
            AssistantMessage("最终结论：通过。团队图可以驱动带流量的仿真工具调用。", ToolCall[]),
        ])

        team = AgentTeam(provider; session_id = session_id)
        result = run_team_graph(team, default_team_graph(), "用多智能体跑一个带地面流量的 AON 仿真")

        @test result.state.status == :completed
        @test [msg.from for msg in result.transcript] == ["planner", "runner", "reviewer"]
        @test occursin("最终结论", result.final_answer)

        runner_messages = team.agents["runner"].messages
        tool_messages = [msg for msg in runner_messages if get(msg, "role", "") == "tool"]
        @test length(tool_messages) == 1

        payload = JSON.parse(tool_messages[1]["content"]; allownan = true)
        @test payload["traffic_enabled"] == true
        @test payload["traffic_demands"] == 1
        @test payload["ground_stations"] == 2
        @test payload["ground_pairs"] == 1
        @test payload["traffic_evaluation_ran"] == true
        @test payload["traffic_fallback"] == false
        @test payload["traffic_time_steps"] == 3
        @test payload["traffic_assignments"] == 2

        runner_ledger = ledger_path(team.agents["runner"].memory)
        @test isfile(runner_ledger)
        @test any(
            line -> occursin("\"event_type\":\"tool_call\"", line) &&
                    occursin("\"tool\":\"run_simulation\"", line) &&
                    occursin("\"status\":\"succeeded\"", line),
            readlines(runner_ledger),
        )
    finally
        cleanup_team_traffic_sessions(session_id)
        clear_hooks!()
    end
end

println("AI TEAM GRAPH TRAFFIC AON: ALL PASS")

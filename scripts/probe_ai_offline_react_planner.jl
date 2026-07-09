#!/usr/bin/env julia

using JSON
using Test
using SatelliteSimLab

function cleanup_ai_probe_session(session_id::AbstractString)
    session_dir = dirname(SatelliteSimLab.SessionMemory(session_id=session_id).transcript_path)
    isdir(session_dir) && rm(session_dir; recursive=true, force=true)
end

@testset "AI offline ReAct and planner probe" begin
    @testset "Tool registry list_available contract" begin
        SatelliteSimLab.ensure_default_ai_tools!()
        tools = SatelliteSimLab.registered_ai_tools()
        raw = SatelliteSimLab.execute_tool(
            "list_available",
            Dict{String,Any}("what" => "propagators"),
        )
        data = JSON.parse(raw)

        @test "list_available" in tools
        @test "plan_study" in tools
        @test data["propagators"] == ["fast", "balanced", "precise", "tle_based"]
    end

    @testset "MockProvider drives full tool-call loop offline" begin
        session_id = "probe_ai_offline_$(rand(UInt))"

        try
            provider = SatelliteSimLab.MockProvider([
                SatelliteSimLab.AssistantMessage("", [
                    SatelliteSimLab.ToolCall(
                        "call_1",
                        "list_available",
                        Dict{String,Any}("what" => "propagators"),
                    ),
                ]),
                SatelliteSimLab.AssistantMessage("可用传播器已经列出。", SatelliteSimLab.ToolCall[]),
            ])

            agent = SatelliteSimLab.SimAgent(provider; session_id=session_id)
            reply = SatelliteSimLab.run_agent(agent, "列出传播器")

            @test reply == "可用传播器已经列出。"
            @test any(message -> get(message, "role", "") == "tool", agent.messages)
            @test provider.cursor == 3
        finally
            cleanup_ai_probe_session(session_id)
            SatelliteSimLab.clear_hooks!()
        end
    end

    @testset "Planner tool builds a study plan offline" begin
        raw = SatelliteSimLab.execute_tool(
            "plan_study",
            Dict{String,Any}(
                "goal" => "coverage_analysis",
                "answers" => Dict{String,Any}(
                    "constellation_coverage" => "global",
                    "constellation_latency" => "low_latency",
                    "constellation_scale" => "small",
                ),
            ),
        )
        data = JSON.parse(raw)

        @test data["goal"] == "coverage_analysis"
        @test data["study_type"] == "CoverageStudy"
    end
end

println("AI OFFLINE REACT PLANNER: ALL PASS")

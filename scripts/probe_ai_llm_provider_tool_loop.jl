#!/usr/bin/env julia

using HTTP
using JSON
using Test
using SatelliteSimLab

function cleanup_tool_loop_session(session_id::AbstractString)
    session_dir = dirname(SatelliteSimLab.SessionMemory(session_id=session_id).transcript_path)
    isdir(session_dir) && rm(session_dir; recursive=true, force=true)
end

@testset "AI LLMProvider SimAgent tool loop probe" begin
    received = Vector{Dict{String,Any}}()

    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request::HTTP.Request
        body = JSON.parse(String(request.body))
        push!(received, body)

        @test request.method == "POST"
        @test String(request.target) == "/v1/chat/completions"
        @test HTTP.header(request, "Authorization") == "Bearer fake-key"

        if length(received) == 1
            @test body["messages"][1]["role"] == "system"
            @test body["messages"][2]["role"] == "user"
            @test body["messages"][2]["content"] == "列出可用传播器"
            @test body["tools"][1]["type"] == "function"
            @test body["tool_choice"] == "auto"

            response = Dict(
                "choices" => [
                    Dict(
                        "message" => Dict(
                            "content" => nothing,
                            "tool_calls" => [
                                Dict(
                                    "id" => "call_list_available_1",
                                    "type" => "function",
                                    "function" => Dict(
                                        "name" => "list_available",
                                        "arguments" => JSON.json(Dict("what" => "propagators")),
                                    ),
                                ),
                            ],
                        ),
                    ),
                ],
            )
            return HTTP.Response(200, ["Content-Type" => "application/json"], JSON.json(response))
        elseif length(received) == 2
            messages = body["messages"]
            assistant_msg = messages[end - 1]
            tool_msg = messages[end]

            @test assistant_msg["role"] == "assistant"
            @test assistant_msg["tool_calls"][1]["id"] == "call_list_available_1"
            @test tool_msg["role"] == "tool"
            @test tool_msg["tool_call_id"] == "call_list_available_1"
            @test occursin("tle_based", tool_msg["content"])

            response = Dict(
                "choices" => [
                    Dict("message" => Dict("content" => "传播器包括 fast/balanced/precise/tle_based。")),
                ],
            )
            return HTTP.Response(200, ["Content-Type" => "application/json"], JSON.json(response))
        end

        return HTTP.Response(500, JSON.json(Dict("error" => "unexpected request")))
    end

    session_id = "probe_fake_openai_tool_loop_$(rand(UInt))"
    try
        provider = SatelliteSimLab.LLMProvider(;
            key="fake-key",
            model="fake-model",
            url="http://127.0.0.1:$(HTTP.port(server))/v1",
            readtimeout_s=5,
        )
        agent = SatelliteSimLab.SimAgent(provider; session_id=session_id)
        reply = SatelliteSimLab.run_agent(agent, "列出可用传播器")

        @test reply == "传播器包括 fast/balanced/precise/tle_based。"
        @test length(received) == 2
        @test count(message -> get(message, "role", "") == "tool", agent.messages) == 1
    finally
        close(server)
        cleanup_tool_loop_session(session_id)
        SatelliteSimLab.clear_hooks!()
    end
end

println("AI LLM PROVIDER TOOL LOOP: ALL PASS")

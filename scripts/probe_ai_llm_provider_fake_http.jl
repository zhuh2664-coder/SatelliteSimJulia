#!/usr/bin/env julia

using HTTP
using JSON
using Test
using SatelliteSimLab

@testset "AI LLMProvider fake HTTP probe" begin
    received = Vector{Dict{String,Any}}()

    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request::HTTP.Request
        @test request.method == "POST"
        @test String(request.target) == "/v1/chat/completions"
        @test HTTP.header(request, "Authorization") == "Bearer fake-key"

        body = JSON.parse(String(request.body))
        push!(received, body)

        @test body["model"] == "fake-model"
        @test body["messages"][1]["role"] == "user"
        @test body["messages"][1]["content"] == "hello fake"

        response = Dict(
            "choices" => [
                Dict(
                    "message" => Dict(
                        "content" => "fake-ok",
                        "tool_calls" => [
                            Dict(
                                "id" => "call_1",
                                "type" => "function",
                                "function" => Dict(
                                    "name" => "run_simulation",
                                    "arguments" => JSON.json(Dict("duration_s" => 60)),
                                ),
                            ),
                        ],
                    ),
                ),
            ],
        )

        return HTTP.Response(200, ["Content-Type" => "application/json"], JSON.json(response))
    end

    try
        port = HTTP.port(server)
        provider = LLMProvider(
            key="fake-key",
            model="fake-model",
            url="http://127.0.0.1:$port/v1",
            readtimeout_s=5,
        )

        messages = [
            Dict("role" => "user", "content" => "hello fake"),
        ]
        tools = [
            Dict(
                "name" => "run_simulation",
                "description" => "fake tool",
                "input_schema" => Dict(
                    "type" => "object",
                    "properties" => Dict("duration_s" => Dict("type" => "integer")),
                    "required" => ["duration_s"],
                ),
            ),
        ]

        message = chat(provider, messages, tools)

        @test message.content == "fake-ok"
        @test length(message.tool_calls) == 1
        @test message.tool_calls[1].id == "call_1"
        @test message.tool_calls[1].name == "run_simulation"
        @test message.tool_calls[1].args["duration_s"] == 60

        @test length(received) == 1
        @test received[1]["tools"][1]["type"] == "function"
        @test received[1]["tools"][1]["function"]["name"] == "run_simulation"
        @test received[1]["tool_choice"] == "auto"
    finally
        close(server)
    end
end

println("AI LLM PROVIDER FAKE HTTP: ALL PASS")

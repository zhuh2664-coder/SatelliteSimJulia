#!/usr/bin/env julia
# Minimal MCP-style stdio server for SatelliteSimJulia tools.
#
# This is a small JSON-RPC server that supports MCP initialize, tools/list,
# and tools/call. It accepts both Content-Length framed messages and newline
# delimited JSON for local smoke testing.

include(joinpath(@__DIR__, "mcp_tool_runner.jl"))

function schema_object(properties::Dict; required=String[])
    return Dict(
        "type" => "object",
        "properties" => properties,
        "required" => required,
        "additionalProperties" => true,
    )
end

const TOOL_SCHEMAS = Dict(
    "list_constellations" => Dict(
        "name" => "list_constellations",
        "description" => "List known SatelliteSimJulia constellation catalog names.",
        "inputSchema" => schema_object(Dict()),
    ),
    "describe_constellation" => Dict(
        "name" => "describe_constellation",
        "description" => "Describe a Walker constellation by catalog name.",
        "inputSchema" => schema_object(Dict("name" => Dict("type" => "string")); required=["name"]),
    ),
    "start_simulation_summary" => Dict(
        "name" => "start_simulation_summary",
        "description" => "Run a bounded constellation propagation and return summary metadata.",
        "inputSchema" => schema_object(Dict(
            "name" => Dict("type" => "string"),
            "tspan" => Dict("type" => "array", "items" => Dict("type" => "number")),
            "step_s" => Dict("type" => "number"),
            "propagator" => Dict("type" => "string"),
            "fps" => Dict("type" => "number"),
        ); required=["name"]),
    ),
    "frame_payload_once" => Dict(
        "name" => "frame_payload_once",
        "description" => "Generate one frame payload for a bounded constellation config.",
        "inputSchema" => schema_object(Dict(
            "name" => Dict("type" => "string"),
            "tspan" => Dict("type" => "array", "items" => Dict("type" => "number")),
            "step_s" => Dict("type" => "number"),
            "propagator" => Dict("type" => "string"),
            "frame_index" => Dict("type" => "integer"),
        ); required=["name"]),
    ),
    "run_pkg_test" => Dict(
        "name" => "run_pkg_test",
        "description" => "Run an allowlisted Julia package test and return a compact result.",
        "inputSchema" => schema_object(Dict("package" => Dict("type" => "string")); required=["package"]),
    ),
    "zcode_token_usage_summary" => Dict(
        "name" => "zcode_token_usage_summary",
        "description" => "Summarize local ZCode token usage without printing message bodies.",
        "inputSchema" => schema_object(Dict(
            "date" => Dict("type" => "string"),
            "top" => Dict("type" => "integer"),
        )),
    ),
)

function read_message(io::IO)
    eof(io) && return nothing
    line = readline(io; keep=true)
    isempty(line) && return nothing

    if startswith(lowercase(line), "content-length:")
        n = parse(Int, strip(split(line, ":", limit=2)[2]))
        # Consume headers until blank line.
        while !eof(io)
            h = readline(io)
            isempty(strip(h)) && break
        end
        bytes = read(io, n)
        return String(bytes)
    end

    stripped = strip(line)
    isempty(stripped) && return nothing
    return stripped
end

function send_message(obj)
    payload = JSON.json(obj)
    write(stdout, "Content-Length: $(sizeof(payload))\r\n\r\n")
    write(stdout, payload)
    flush(stdout)
end

function rpc_result(id, result)
    return Dict("jsonrpc" => "2.0", "id" => id, "result" => result)
end

function rpc_error(id, code::Int, message::String)
    return Dict("jsonrpc" => "2.0", "id" => id, "error" => Dict("code" => code, "message" => message))
end

function handle_request(req::AbstractDict)
    method = get(req, "method", "")
    id = get(req, "id", nothing)

    if method == "initialize"
        return rpc_result(id, Dict(
            "protocolVersion" => "2024-11-05",
            "capabilities" => Dict("tools" => Dict("listChanged" => false)),
            "serverInfo" => Dict("name" => "satellitesimjulia", "version" => "0.1.0"),
        ))
    elseif method == "notifications/initialized"
        return nothing
    elseif method == "tools/list"
        tools = [TOOL_SCHEMAS[name] for name in sort(collect(keys(TOOL_SCHEMAS)))]
        return rpc_result(id, Dict("tools" => tools))
    elseif method == "tools/call"
        params = get(req, "params", Dict())
        name = String(get(params, "name", ""))
        args = get(params, "arguments", Dict())
        haskey(TOOLS, name) || return rpc_error(id, -32602, "unknown tool: $name")
        try
            result = TOOLS[name](args)
            text = JSON.json(Dict("ok" => true, "tool" => name, "result" => result))
            return rpc_result(id, Dict("content" => [Dict("type" => "text", "text" => text)], "isError" => false))
        catch e
            text = JSON.json(Dict("ok" => false, "tool" => name, "error_type" => string(typeof(e)), "message" => sprint(showerror, e)))
            return rpc_result(id, Dict("content" => [Dict("type" => "text", "text" => text)], "isError" => true))
        end
    elseif method == "shutdown"
        return rpc_result(id, nothing)
    else
        return rpc_error(id, -32601, "method not found: $method")
    end
end

function serve_stdio()
    while !eof(stdin)
        raw = read_message(stdin)
        raw === nothing && continue
        req = try
            JSON.parse(raw)
        catch e
            send_message(rpc_error(nothing, -32700, "parse error: $(sprint(showerror, e))"))
            continue
        end
        resp = handle_request(req)
        resp === nothing || send_message(resp)
    end
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    serve_stdio()
end

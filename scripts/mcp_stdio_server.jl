#!/usr/bin/env julia
# SatelliteSimJulia 的最小 MCP-style stdio server。
#
# 该 server 故意只暴露 scripts/mcp_tool_runner.jl 中的只读 safe tools：
# list_constellations 与 describe_constellation。仿真、传播、frame payload、
# package test、export、写文件等工具不会被 tools/list 广播，也不能通过
# tools/call 触达。
#
# 这是一个小型 JSON-RPC server，支持 MCP initialize、tools/list 与 tools/call。
# 它同时接受标准 Content-Length framed 消息和用于本地 smoke test 的
# newline-delimited JSON。

include(joinpath(@__DIR__, "mcp_tool_runner.jl"))

function schema_object(properties::Dict; required=String[])
    return Dict(
        "type" => "object",
        "properties" => properties,
        "required" => required,
        "additionalProperties" => false,
    )
end

const TOOL_SCHEMAS = Dict(
    "list_constellations" => Dict(
        "name" => "list_constellations",
        "description" => "List known SatelliteSimJulia constellation catalog names. Read-only safe tool.",
        "inputSchema" => schema_object(Dict()),
    ),
    "describe_constellation" => Dict(
        "name" => "describe_constellation",
        "description" => "Describe a Walker constellation by catalog name. Read-only safe tool.",
        "inputSchema" => schema_object(Dict("name" => Dict("type" => "string")); required=["name"]),
    ),
)

function read_message(io::IO)
    eof(io) && return nothing
    line = readline(io; keep=true)
    isempty(line) && return nothing

    if startswith(lowercase(line), "content-length:")
        n = parse(Int, strip(split(line, ":", limit=2)[2]))
        # 读取并丢弃 headers，直到空行。
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
        haskey(TOOL_SCHEMAS, name) || return rpc_error(id, -32602, "unknown or disabled safe tool: $name")
        haskey(TOOLS, name) || return rpc_error(id, -32602, "tool is not present in safe runner dispatch: $name")
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

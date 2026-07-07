#!/usr/bin/env julia
# SatelliteSimJulia 的最小 MCP-ready JSON 工具 runner。
#
# 安全边界：该 runner 默认只读，只 dispatch 安全的目录查询工具。
# 测试、frame payload 生成、传播、export、写文件等有副作用或高成本工具
# 均故意不放入 TOOLS，不能通过 dispatch 触达。
#
# 用法：
#   julia --project=. scripts/mcp_tool_runner.jl list_constellations '{}'
#   julia --project=. scripts/mcp_tool_runner.jl describe_constellation '{"name":"iridium"}'

using JSON
using SatelliteSimCore

function emit(obj)
    println(JSON.json(obj))
end

function require_key(args::AbstractDict, key::String)
    haskey(args, key) || throw(ArgumentError("missing required argument: $key"))
    return args[key]
end

function walker_config(name::String)
    cfg = resolve_constellation(Symbol(name))
    cfg isa WalkerConstellationConfig || throw(ArgumentError("only WalkerConstellationConfig is supported, got $(typeof(cfg))"))
    return cfg
end

function tool_list_constellations(args::AbstractDict)
    return Dict("names" => String.(string.(list_constellations())))
end

function tool_describe_constellation(args::AbstractDict)
    name = String(require_key(args, "name"))
    cfg = walker_config(name)
    return Dict(
        "name" => name,
        "T" => cfg.T,
        "P" => cfg.P,
        "F" => cfg.F,
        "alt_km" => cfg.alt_km,
        "inc_deg" => cfg.inc_deg,
    )
end

const TOOLS = Dict{String,Function}(
    "list_constellations" => tool_list_constellations,
    "describe_constellation" => tool_describe_constellation,
)

function main(argv)
    length(argv) >= 1 || throw(ArgumentError("usage: mcp_tool_runner.jl <tool-name> '<json-args>'"))
    tool = argv[1]
    haskey(TOOLS, tool) || throw(ArgumentError("unknown or disabled safe tool: $tool"))
    raw_args = length(argv) >= 2 ? argv[2] : "{}"
    parsed = JSON.parse(raw_args)
    parsed isa AbstractDict || throw(ArgumentError("json args must be an object"))
    result = TOOLS[tool](parsed)
    emit(Dict("ok" => true, "tool" => tool, "result" => result))
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    try
        main(ARGS)
    catch e
        tool = length(ARGS) >= 1 ? ARGS[1] : ""
        emit(Dict(
            "ok" => false,
            "tool" => tool,
            "error_type" => string(typeof(e)),
            "message" => sprint(showerror, e),
        ))
        exit(1)
    end
end

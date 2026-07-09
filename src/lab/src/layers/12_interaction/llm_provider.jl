# ===== LLM Provider — OpenAI 兼容实现 =====
# Phase 3：HTTP/JSON 下沉至此文件。
# ToolCall/AssistantMessage/AbstractLLMProvider 定义在 llm_provider_trait.jl（先 include）。

using HTTP
using JSON

export LLMProvider, OpenAICompatibleProvider, chat, build_tool_schemas

"""
    OpenAICompatibleProvider <: AbstractLLMProvider

兼容 OpenAI 格式的 HTTP provider（DeepSeek / GPT / Claude proxy）。
HTTP 依赖封装在此类型，不影响 MockProvider/CLIProvider 的加载。
"""
struct OpenAICompatibleProvider <: AbstractLLMProvider
    api_key::String
    model::String
    base_url::String
end

function OpenAICompatibleProvider(;
    key::String = get(ENV, "DEEPSEEK_API_KEY", ""),
    model::String = "deepseek-chat",
    url::String = "https://api.deepseek.com/v1",
)
    isempty(key) && @warn "LLM API key 为空，请设置 DEEPSEEK_API_KEY 或传 key= 参数"
    return OpenAICompatibleProvider(key, model, url)
end

function chat(p::OpenAICompatibleProvider, messages::Vector, tools::Vector = Dict[])
    body = Dict{String,Any}(
        "model" => p.model,
        "messages" => messages,
    )
    if !isempty(tools)
        body["tools"] = [_openai_tool(t) for t in tools]
        body["tool_choice"] = "auto"
    end

    resp = HTTP.post(
        "$(p.base_url)/chat/completions",
        ["Authorization" => "Bearer $(p.api_key)",
         "Content-Type" => "application/json"],
        JSON.json(body);
        readtimeout = 120,
    )

    data = JSON.parse(String(resp.body))
    choice = data["choices"][1]["message"]
    content = get(choice, "content", "")
    content = content === nothing ? "" : string(content)

    tool_calls = ToolCall[]
    for tc in get(choice, "tool_calls", [])
        push!(tool_calls, ToolCall(
            tc["id"],
            tc["function"]["name"],
            JSON.parse(tc["function"]["arguments"]),
        ))
    end

    return AssistantMessage(content, tool_calls)
end

# backward-compat：旧代码 LLMProvider() 仍可用
const LLMProvider = OpenAICompatibleProvider

function _openai_tool(tool::Dict)
    return Dict(
        "type" => "function",
        "function" => Dict(
            "name" => tool["name"],
            "description" => get(tool, "description", ""),
            "parameters" => get(tool, "input_schema", Dict()),
        ),
    )
end

"""
    build_tool_schemas() -> Vector{Dict}

从 lab 的 goal/study 体系自动构建 LLM 工具 schema。
"""
function build_tool_schemas()
    schemas = Dict{String,Any}[]

    push!(schemas, Dict(
        "name" => "run_simulation",
        "description" => "运行星座网络仿真。可指定星座规模、网络拓扑特性、传播精度、仿真时长等参数。",
        "input_schema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "constellation" => Dict("type" => "string", "description" => "星座名或 'walker T/P/F'，如 'iridium' 或 'walker 66/6/2'"),
                "topology" => Dict("type" => "string",
                    "enum" => ["balanced", "robust", "minimal", "adaptive"],
                    "default" => "balanced",
                    "description" => "网络拓扑特性：balanced=均衡网格(默认) | robust=高鲁棒蜂窝 | minimal=最小链路环 | adaptive=自适应最近邻"),
                "propagator" => Dict("type" => "string",
                    "enum" => ["fast", "balanced", "precise", "tle_based"],
                    "default" => "fast",
                    "description" => "轨道传播精度：fast=快速二体(默认) | balanced=含J2摄动 | precise=高精度J4 | tle_based=真实TLE/SGP4"),
                "duration_s" => Dict("type" => "number", "default" => 600, "description" => "仿真时长（秒）"),
                "steps" => Dict("type" => "integer", "default" => 2),
            ),
            "required" => ["constellation"],
        ),
    ))

    push!(schemas, Dict(
        "name" => "scan_parameter",
        "description" => "扫描单一参数对网络性能的影响（如高度、倾角、面数）。",
        "input_schema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "base_constellation" => Dict("type" => "string", "default" => "walker 24/6/1"),
                "param" => Dict("type" => "string", "enum" => ["alt_km", "inc_deg", "P", "T"], "description" => "扫描参数"),
                "values" => Dict("type" => "array", "items" => Dict("type" => "number"), "description" => "参数值列表"),
            ),
            "required" => ["param", "values"],
        ),
    ))

    push!(schemas, Dict(
        "name" => "compare_constellations",
        "description" => "对比多个星座的网络性能（覆盖、时延、连通性）。",
        "input_schema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "constellations" => Dict("type" => "array", "items" => Dict("type" => "string"), "description" => "星座名列表，如 ['iridium','starlink_gen1','oneweb']"),
            ),
            "required" => ["constellations"],
        ),
    ))

    push!(schemas, Dict(
        "name" => "list_available",
        "description" => "列出可用的星座预设、拓扑策略、传播器等。",
        "input_schema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "what" => Dict("type" => "string", "enum" => ["constellations", "topologies", "propagators", "all"], "default" => "all"),
            ),
        ),
    ))

    return schemas
end

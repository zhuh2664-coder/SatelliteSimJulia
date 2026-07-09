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
    readtimeout_s::Int
end

OpenAICompatibleProvider(api_key::String, model::String, base_url::String) =
    OpenAICompatibleProvider(api_key, model, base_url, 120)

function OpenAICompatibleProvider(;
    key::String = get(ENV, "DEEPSEEK_API_KEY", ""),
    model::String = "deepseek-chat",
    url::String = "https://api.deepseek.com/v1",
    readtimeout_s::Int = 120,
)
    isempty(key) && @warn "LLM API key 为空，请设置 DEEPSEEK_API_KEY 或传 key= 参数"
    readtimeout_s > 0 || throw(ArgumentError("readtimeout_s must be positive"))
    return OpenAICompatibleProvider(key, model, url, readtimeout_s)
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
        read_idle_timeout = p.readtimeout_s,
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
    if isdefined(@__MODULE__, :ensure_default_ai_tools!)
        ensure_default_ai_tools!()
        return build_registered_tool_schemas()
    end
    return Dict{String,Any}[]
end

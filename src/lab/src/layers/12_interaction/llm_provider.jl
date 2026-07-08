# ===== LLM Provider — 统一 LLM 调用接口 =====
# 整合自 project_docs/simagentcli + project_docs/cli 两份原型
# 支持 OpenAI 格式（DeepSeek/GPT/Claude via proxy）
#
# 这是 AI 适配层的"最后一块拼图"——把 lab 包的 study 体系接到 LLM

using HTTP
using JSON

export AbstractLLMProvider, LLMProvider, ToolCall, AssistantMessage,
       chat, build_tool_schemas, llm_tool_schema

abstract type AbstractLLMProvider end

"""
    LLMProvider

LLM 提供者配置。兼容 OpenAI 格式的 API（DeepSeek/GPT/任何 OpenAI 兼容端点）。
"""
struct LLMProvider <: AbstractLLMProvider
    api_key::String
    model::String
    base_url::String
    readtimeout_s::Int
end

LLMProvider(api_key::String, model::String, base_url::String) =
    LLMProvider(api_key, model, base_url, 120)

"""
    LLMProvider(; key, model, url, readtimeout_s)

构造 LLM Provider。默认从环境变量读 DeepSeek API key。

```julia
provider = LLMProvider()  # 自动读 DEEPSEEK_API_KEY
provider = LLMProvider(key="sk-xxx", model="gpt-4o", url="https://api.openai.com/v1", readtimeout_s=300)
```
"""
function LLMProvider(;
    key::String = get(ENV, "DEEPSEEK_API_KEY", ""),
    model::String = "deepseek-chat",
    url::String = "https://api.deepseek.com/v1",
    readtimeout_s::Int = 120,
)
    isempty(key) && @warn "LLM API key 为空，设置 DEEPSEEK_API_KEY 或传 key= 参数"
    readtimeout_s > 0 || error("readtimeout_s must be positive")
    return LLMProvider(key, model, url, readtimeout_s)
end

"""
    ToolCall

LLM 返回的工具调用请求。
"""
struct ToolCall
    id::String
    name::String
    args::Dict{String,Any}
end

"""
    AssistantMessage

LLM 返回的助手消息（可能包含文本 + 工具调用）。
"""
struct AssistantMessage
    content::String
    tool_calls::Vector{ToolCall}
end

"""
    chat(provider, messages, tools) -> AssistantMessage

调用 LLM，返回助手消息（可能含 tool_calls）。

- `messages`: OpenAI 格式消息数组
- `tools`: 工具 schema 数组（Dict 格式）

```julia
msg = chat(provider, [
    Dict("role" => "system", "content" => "你是仿真助手"),
    Dict("role" => "user", "content" => "帮我跑一个 66/6 星座的覆盖分析"),
], tool_schemas)
```
"""
function chat(provider::LLMProvider, messages::Vector, tools::Vector = Dict[])
    body = Dict(
        "model" => provider.model,
        "messages" => messages,
    )
    if !isempty(tools)
        body["tools"] = [_openai_tool(t) for t in tools]
        body["tool_choice"] = "auto"
    end

    resp = HTTP.post(
        "$(provider.base_url)/chat/completions",
        ["Authorization" => "Bearer $(provider.api_key)",
         "Content-Type" => "application/json"],
        JSON.json(body);
        read_idle_timeout = provider.readtimeout_s,
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

# OpenAI 工具格式转换
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

# ─── 工具 Schema 构建（桥接 lab 的 study/goal 体系）───

"""
    build_tool_schemas() -> Vector{Dict}

从 lab 的 goal/study 体系自动构建 LLM 工具 schema。
每个 goal 变成一个工具，LLM 可以通过 function-calling 调用。
"""
function build_tool_schemas()
    if isdefined(@__MODULE__, :ensure_default_ai_tools!)
        ensure_default_ai_tools!()
        return build_registered_tool_schemas()
    end
    # tool_registry.jl 尚未 include 时的保守 fallback。正常模块加载完成后不会走到这里。
    return Dict{String,Any}[]
end

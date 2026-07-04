# ===== LLM Provider — 统一 LLM 调用接口 =====
# 整合自 project_docs/simagentcli + project_docs/cli 两份原型
# 支持 OpenAI 格式（DeepSeek/GPT/Claude via proxy）
#
# 这是 AI 适配层的"最后一块拼图"——把 lab 包的 study 体系接到 LLM

using HTTP
using JSON

export LLMProvider, ToolCall, AssistantMessage,
       chat, build_tool_schemas, llm_tool_schema

"""
    LLMProvider

LLM 提供者配置。兼容 OpenAI 格式的 API（DeepSeek/GPT/任何 OpenAI 兼容端点）。
"""
struct LLMProvider
    api_key::String
    model::String
    base_url::String
end

"""
    LLMProvider(; key, model, url)

构造 LLM Provider。默认从环境变量读 DeepSeek API key。

```julia
provider = LLMProvider()  # 自动读 DEEPSEEK_API_KEY
provider = LLMProvider(key="sk-xxx", model="gpt-4o", url="https://api.openai.com/v1")
```
"""
function LLMProvider(;
    key::String = get(ENV, "DEEPSEEK_API_KEY", ""),
    model::String = "deepseek-chat",
    url::String = "https://api.deepseek.com/v1",
)
    isempty(key) && @warn "LLM API key 为空，设置 DEEPSEEK_API_KEY 或传 key= 参数"
    return LLMProvider(key, model, url)
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
    schemas = Dict{String,Any}[]

    # run_study 工具——通用仿真入口
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

    # scan_parameter 工具——参数扫描
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

    # compare_constellations 工具——星座对比
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

    # list_available 工具——列出可用资源
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

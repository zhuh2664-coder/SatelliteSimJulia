# ===== LLMProvider Trait — Phase 3 =====
# 共享数据结构 + 抽象 provider 层 + 零依赖实现（Mock/CLI）
# OpenAICompatibleProvider（HTTP）定义在 llm_provider.jl，因为那里 using HTTP
#
# include 顺序（由 SatelliteSimLab.jl 保证）：
#   1. llm_provider_trait.jl  ← 本文件（无 HTTP）
#   2. llm_provider.jl        ← HTTP + OpenAICompatibleProvider + LLMProvider alias

export AbstractLLMProvider, MockProvider, CLIProvider
export ToolCall, AssistantMessage

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
    AbstractLLMProvider

LLM 提供者抽象类型。新 provider = 新类型 + 新 chat 方法，不改已有代码。

内置实现：
- `OpenAICompatibleProvider`（llm_provider.jl）：HTTP，生产用
- `MockProvider`：固定回复，零 HTTP，测试用
- `CLIProvider`：stdin 交互，本地模型 stub
"""
abstract type AbstractLLMProvider end

function chat(::AbstractLLMProvider, ::Vector, ::Vector = Dict[])
    error("未实现 chat 方法，请为你的 AbstractLLMProvider 子类型定义 chat")
end

# ── MockProvider — 零依赖，测试用 ────────────────────────────────────────────

"""
    MockProvider <: AbstractLLMProvider

按顺序返回预设回复；用完后循环最后一个。零外部依赖，适合单元测试。
"""
struct MockProvider <: AbstractLLMProvider
    responses::Vector{String}
    _idx::Ref{Int}
end

MockProvider(responses::Vector{String} = ["[mock response]"]) =
    MockProvider(responses, Ref(1))

function chat(p::MockProvider, messages::Vector, tools::Vector = Dict[])
    response = p.responses[min(p._idx[], length(p.responses))]
    p._idx[] = min(p._idx[] + 1, length(p.responses))
    return AssistantMessage(response, ToolCall[])
end

# ── CLIProvider — stdin 交互，本地模型 stub ───────────────────────────────────

"""
    CLIProvider <: AbstractLLMProvider

从 stdin 读取响应（适合本地 CLI 模型或人工介入测试）。
"""
struct CLIProvider <: AbstractLLMProvider end

function chat(::CLIProvider, messages::Vector, tools::Vector = Dict[])
    last_user = ""
    for m in reverse(messages)
        if get(m, "role", "") == "user"
            last_user = get(m, "content", "")
            break
        end
    end
    println("\n[CLIProvider] User: ", last_user)
    print("[CLIProvider] Response: ")
    return AssistantMessage(readline(), ToolCall[])
end

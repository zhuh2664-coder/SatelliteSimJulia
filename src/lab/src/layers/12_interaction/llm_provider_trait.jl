# ===== LLM provider trait and zero-network implementations =====

export AbstractLLMProvider, MockProvider, CLIProvider
export ToolCall, AssistantMessage, chat

"""A tool invocation requested by an assistant message."""
struct ToolCall
    id::String
    name::String
    args::Dict{String,Any}
end

"""A provider-neutral assistant response."""
struct AssistantMessage
    content::String
    tool_calls::Vector{ToolCall}
end

"""Provider interface. Implement `chat(provider, messages, tools)`."""
abstract type AbstractLLMProvider end

function chat(::AbstractLLMProvider, ::Vector, ::Vector = Dict[])
    error("未实现 chat 方法，请为 AbstractLLMProvider 子类型定义 chat")
end

"""
    MockProvider(responses)

Deterministic, zero-network provider. `responses` may be assistant messages or strings.
After the script is exhausted the last response is repeated, which keeps interactive
callers deterministic while allowing one-response smoke tests.
"""
mutable struct MockProvider <: AbstractLLMProvider
    responses::Vector{AssistantMessage}
    cursor::Int
end

MockProvider() = MockProvider([AssistantMessage("[mock response]", ToolCall[])], 1)
MockProvider(responses::AbstractVector{<:AssistantMessage}) =
    MockProvider(AssistantMessage[responses...], 1)
MockProvider(responses::AbstractVector{<:AbstractString}) =
    MockProvider([AssistantMessage(String(response), ToolCall[]) for response in responses], 1)

function chat(provider::MockProvider, ::Vector, ::Vector = Dict[])
    isempty(provider.responses) && return AssistantMessage("", ToolCall[])
    index = min(provider.cursor, length(provider.responses))
    message = provider.responses[index]
    provider.cursor = min(provider.cursor + 1, length(provider.responses))
    return message
end

"""Interactive stdin provider used for local/manual testing."""
struct CLIProvider <: AbstractLLMProvider end

function chat(::CLIProvider, messages::Vector, ::Vector = Dict[])
    last_user = ""
    for message in reverse(messages)
        if get(message, "role", "") == "user"
            last_user = string(get(message, "content", ""))
            break
        end
    end
    println("\n[CLIProvider] User: ", last_user)
    print("[CLIProvider] Response: ")
    return AssistantMessage(readline(), ToolCall[])
end

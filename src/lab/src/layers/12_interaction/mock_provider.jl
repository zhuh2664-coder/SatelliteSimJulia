# ===== Mock LLM provider for tests =====

export MockProvider

mutable struct MockProvider <: AbstractLLMProvider
    responses::Vector{AssistantMessage}
    cursor::Int
end

MockProvider(responses::Vector{AssistantMessage}) = MockProvider(responses, 1)

function chat(provider::MockProvider, messages::Vector, tools::Vector = Dict[])
    provider.cursor <= length(provider.responses) || return AssistantMessage("", ToolCall[])
    msg = provider.responses[provider.cursor]
    provider.cursor += 1
    return msg
end

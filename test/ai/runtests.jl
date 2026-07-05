using Test

@testset "AI layer" begin
    include("test_tool_registry.jl")
    include("test_agent_hooks.jl")
    include("test_tool_guards.jl")
    include("test_ledger.jl")
    include("test_mock_provider.jl")
    include("test_multiagent.jl")
end

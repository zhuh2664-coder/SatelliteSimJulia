using Test

@testset "AI layer" begin
    include("test_llm_provider.jl")
    include("test_tool_registry.jl")
    include("test_agent_hooks.jl")
    include("test_tool_guards.jl")
    include("test_tool_validation_permissions.jl")
    include("test_ledger.jl")
    include("test_event_runtime.jl")
    include("test_trace.jl")
    include("test_mock_provider.jl")
    include("test_multiagent.jl")
    include("test_agent_worker.jl")
    include("test_team_graph.jl")
    include("test_team_artifacts.jl")
    include("test_team_graph_checkpoint.jl")
    include("test_evals_replay.jl")
    include("test_ai_runs.jl")
end

module SatelliteSimLab

using SatelliteSimCore
using SatelliteSimNet
using SatelliteSimTraffic: TrafficDemand

# Layer 11: experiment contracts and the single execution path.
include("layers/11_experiment/intent.jl")
include("layers/11_experiment/state.jl")
include("layers/11_experiment/entities.jl")
include("layers/11_experiment/intent_resolution.jl")
include("layers/11_experiment/config.jl")
include("layers/11_experiment/results.jl")
include("layers/11_experiment/traffic_scenarios.jl")
include("layers/11_experiment/precomposed.jl")
include("layers/11_experiment/runner.jl")
include("layers/11_experiment/checkpoint.jl")
include("layers/11_experiment/cache.jl")
include("layers/11_experiment/experiment.jl")
include("layers/11_experiment/database.jl")
include("layers/11_experiment/export.jl")
include("layers/11_experiment/sweep.jl")

# Layer 12: provider-neutral interaction and orchestration.
include("layers/12_interaction/studies.jl")
include("layers/12_interaction/goals.jl")
include("layers/12_interaction/planner/planner.jl")
include("layers/12_interaction/questionnaire/questionnaire.jl")
include("layers/12_interaction/llm_provider_trait.jl")
include("layers/12_interaction/llm_provider.jl")
include("layers/12_interaction/hooks.jl")
include("layers/12_interaction/tool_validation.jl")
include("layers/12_interaction/tool_guards.jl")
include("layers/12_interaction/memory.jl")
include("layers/12_interaction/ledger.jl")
include("layers/12_interaction/event_runtime.jl")
include("layers/12_interaction/trace.jl")
include("layers/12_interaction/tool_permissions.jl")
include("layers/12_interaction/agent.jl")
include("layers/12_interaction/multiagent.jl")
include("layers/12_interaction/agent_worker.jl")
include("layers/12_interaction/team_graph.jl")
include("layers/12_interaction/team_artifacts.jl")
include("layers/12_interaction/team_graph_checkpoint.jl")
include("layers/12_interaction/evals.jl")
include("layers/12_interaction/replay.jl")
include("layers/12_interaction/ai_runs.jl")
include("layers/12_interaction/demo.jl")
include("layers/12_interaction/tool_inputs.jl")
include("layers/12_interaction/tool_registry.jl")
include("layers/12_interaction/planner_tools.jl")
include("layers/12_interaction/study_dsl.jl")

end # module

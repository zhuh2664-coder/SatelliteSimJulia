module SatelliteSimLab

using SatelliteSimCore
using SatelliteSimNet
using SatelliteSimTraffic: TrafficDemand

# Lab 的依赖方向固定为：
#   intent/config → resolution → runner → result ← interaction/agent/demo
# 先加载实验编排内核，再加载仅调用稳定编排 API 的交互适配层，避免依赖 include 顺序
# 或通过宽泛聚合导出取得隐式能力。

# ── 实验编排内核 ─────────────────────────────────────────────
include("layers/11_experiment/intent.jl")
include("layers/11_experiment/state.jl")
include("layers/11_experiment/entities.jl")
include("layers/11_experiment/config.jl")
include("layers/11_experiment/intent_resolution.jl")
include("layers/11_experiment/results.jl")
include("layers/11_experiment/traffic_scenarios.jl")
include("layers/11_experiment/runner.jl")
include("layers/11_experiment/checkpoint.jl")
include("layers/11_experiment/cache.jl")
include("layers/11_experiment/precomposed.jl")
include("layers/11_experiment/experiment.jl")
include("layers/11_experiment/database.jl")
include("layers/11_experiment/export.jl")
include("layers/11_experiment/sweep.jl")

# ── 交互与集成适配层 ─────────────────────────────────────────
# 此层可以组合上面的公开编排 API，但不反向定义实验领域能力。
include("layers/12_interaction/studies.jl")
include("layers/12_interaction/goals.jl")
include("layers/12_interaction/study_dsl.jl")
include("layers/12_interaction/planner/planner.jl")
include("layers/12_interaction/questionnaire/questionnaire.jl")
include("layers/12_interaction/llm_provider_trait.jl")
include("layers/12_interaction/llm_provider.jl")
include("layers/12_interaction/hooks.jl")
include("layers/12_interaction/memory.jl")
include("layers/12_interaction/agent.jl")

# 保持日常仿真兼容入口；演示只能使用根包契约内的能力。
include("layers/12_interaction/demo.jl")

end # module

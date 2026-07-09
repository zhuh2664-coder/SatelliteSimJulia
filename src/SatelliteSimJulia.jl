module SatelliteSimJulia

# 日常仿真门面。低层领域包与交互/Agent 集成必须显式导入对应子包，
# 以免根包再次成为无边界的聚合命名空间。
using SatelliteSimLab: demo, run_examples,
    ExperimentConfig, ExperimentResult, run_experiment,
    study, walker, run_study,
    assess_coverage, assess_routing, full_constellation_assessment

export satnet,
       demo, run_examples,
       ExperimentConfig, ExperimentResult, run_experiment,
       study, walker, run_study,
       assess_coverage, assess_routing, full_constellation_assessment

include("cli/SimCLI.jl")
using .SimCLI

"""
    satnet(args::Vector{String})

SimCLI 入口。`bin/satnet.jl` 调用此函数。
"""
satnet(args::Vector{String}) = SimCLI.command_main(args)

include("cli/SimCLI.jl")
using .SimCLI

"""
    satnet(args::Vector{String})

SimCLI 入口。`bin/satnet.jl` 调用此函数。
"""
satnet(args::Vector{String}) = SimCLI.command_main(args)

end # module

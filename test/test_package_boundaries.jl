# ===== 包边界契约 =====
#
# 日常仿真入口只暴露主链编排能力；高级包必须显式导入。
# 依赖图的静态约束由 scripts/check_dependency_boundaries.jl 执行。

using TOML
using SatelliteSimNet
using SatelliteSimTraffic
using SatelliteSimLab

const _REFACTOR_ROOT = normpath(joinpath(@__DIR__, ".."))

function _package_dependencies(package_dir::String)
    project = TOML.parsefile(joinpath(_REFACTOR_ROOT, "src", package_dir, "Project.toml"))
    return get(project, "deps", Dict{String,Any}())
end

@testset "包边界契约" begin
    @test isdefined(SatelliteSimNet, :RoutingGraph)
    @test isdefined(SatelliteSimTraffic, :TrafficDemand)

    # 根包只暴露日常编排门面；高级、交互和低层能力均须显式导入。
    @test !isdefined(SatelliteSimJulia, :aon_throughput)
    @test !isdefined(SatelliteSimJulia, :propagate_with_gradient)
    @test !isdefined(SatelliteSimJulia, :AbstractAttack)
    # Net/Lab/Traffic 兼容 re-export 暂时保留，避免本轮破坏已有用户代码。
    @test isdefined(SatelliteSimJulia, :agent_repl)
    @test isdefined(SatelliteSimJulia, :LLMProvider)
    @test isdefined(SatelliteSimJulia, :GridPlusStrategy)
    @test isdefined(SatelliteSimJulia, :run_experiment)
    @test isdefined(SatelliteSimJulia, :run_study)
    @test isdefined(SatelliteSimLab, :agent_repl)
    @test isdefined(SatelliteSimLab, :LLMProvider)

    # 这些层各自声明下游依赖，而不是把 Core 当作万能转发站。
    @test !haskey(_package_dependencies("net"), "SatelliteSimCore")
    @test !haskey(_package_dependencies("traffic"), "SatelliteSimCore")
    @test !haskey(_package_dependencies("security"), "SatelliteSimCore")
    @test !haskey(_package_dependencies("opt"), "SatelliteSimCore")
end

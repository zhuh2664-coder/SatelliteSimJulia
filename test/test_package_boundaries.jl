# ===== 包边界契约 =====
#
# 日常仿真入口只透传 Core/Net/Lab/Traffic；高级包必须显式导入。
# 同时约束 Net、Traffic、Security 不得再通过 Core 的聚合 re-export
# 获得底层类型，避免依赖图退化为隐式的上行依赖。

using TOML
using SatelliteSimNet
using SatelliteSimTraffic
using SatelliteSimSecurity

const _REFACTOR_ROOT = normpath(joinpath(@__DIR__, ".."))

function _package_dependencies(package_dir::String)
    project = TOML.parsefile(joinpath(_REFACTOR_ROOT, "src", package_dir, "Project.toml"))
    return get(project, "deps", Dict{String,Any}())
end

@testset "包边界契约" begin
    @test isdefined(SatelliteSimNet, :RoutingGraph)
    @test isdefined(SatelliteSimTraffic, :TrafficDemand)
    @test isdefined(SatelliteSimSecurity, :AbstractAttack)

    # 高级功能不应因 `using SatelliteSimJulia` 而被隐式载入。
    @test !isdefined(SatelliteSimJulia, :aon_throughput)
    @test !isdefined(SatelliteSimJulia, :propagate_with_gradient)
    @test !isdefined(SatelliteSimJulia, :AbstractAttack)

    # 这些层各自声明下游依赖，而不是把 Core 当作万能转发站。
    @test !haskey(_package_dependencies("net"), "SatelliteSimCore")
    @test !haskey(_package_dependencies("traffic"), "SatelliteSimCore")
    @test !haskey(_package_dependencies("security"), "SatelliteSimCore")
    @test !haskey(_package_dependencies("opt"), "SatelliteSimCore")
end

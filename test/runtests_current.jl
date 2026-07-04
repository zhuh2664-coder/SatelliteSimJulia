# test/runtests_current.jl — 当前架构回归测试主入口
#
# 设计原则：
# - 不修改旧 test/runtests.jl，新建入口与其并存
# - 只 include 当前公开 API 下能 green 的模块化测试
# - 未来逐步把旧 runtests.jl 中的有效断言迁移为独立文件

push!(LOAD_PATH, "@stdlib")

using SatelliteSimJulia
using Dates
using Test

const HAS_GLMAKIE = try
    @eval import GLMakie
    true
catch
    false
end

# 共享 fixture（ walker 星座、时间网格、地面站等）
include(joinpath(@__DIR__, "test_helpers.jl"))

@testset "SatelliteSimJulia current test suite" begin
    @testset "Foundation" begin
        # 时间、坐标、实体等基础类型已有 smoke 覆盖；后续拆分为独立文件
        @test SatelliteSimJulia.SimulationEpoch isa DataType
        @test SatelliteSimJulia.CartesianState isa DataType
    end

    @testset "Orbit" begin
        include(joinpath(@__DIR__, "orbit", "test_walker.jl"))
    end

    @testset "Link" begin
        include(joinpath(@__DIR__, "link", "test_gsl.jl"))
    end

    @testset "Net" begin
        include(joinpath(@__DIR__, "test_topology_strategies.jl"))
        include(joinpath(@__DIR__, "test_topology_metrics.jl"))
        include(joinpath(@__DIR__, "net", "test_routing.jl"))
        include(joinpath(@__DIR__, "test_cgr.jl"))
    end

    @testset "Metrics" begin
        include(joinpath(@__DIR__, "test_metrics.jl"))
    end

    @testset "Optimization" begin
        include(joinpath(@__DIR__, "test_end_to_end_gradient.jl"))
    end

    @testset "Security" begin
        include(joinpath(@__DIR__, "test_security.jl"))
    end

    @testset "Integration" begin
        include(joinpath(@__DIR__, "integration", "test_e2e.jl"))
    end

    if HAS_GLMAKIE
        @testset "Viz" begin
            # GLMakie 相关测试在可用时加入
        end
    end
end

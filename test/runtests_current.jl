# test/runtests_current.jl — 当前架构回归测试主入口
#
# 设计原则：
# - 不修改旧 test/runtests.jl，新建入口与其并存
# - 只 include 当前公开 API 下能 green 的模块化测试
# - 未来逐步把旧 runtests.jl 中的有效断言迁移为独立文件

push!(LOAD_PATH, "@stdlib")

using SatelliteSimJulia
using SatelliteSimFoundation
using Dates
using Test

const HAS_GLMAKIE = try
    @eval import GLMakie
    true
catch
    false
end

# 慢测试守卫：默认跳过 Optimization（单 testset 5m48s），
# 设 SATSIM_RUN_SLOW=1 跑全量。这是"偶尔能测而非每次阻塞"的落地。
const RUN_SLOW = get(ENV, "SATSIM_RUN_SLOW", "0") == "1"

# 共享 fixture（ walker 星座、时间网格、地面站等）
include(joinpath(@__DIR__, "test_helpers.jl"))

@testset "SatelliteSimJulia current test suite" begin
    @testset "Foundation" begin
        # 时间、坐标、实体等基础类型已有 smoke 覆盖；后续拆分为独立文件
@test SatelliteSimFoundation.SimulationEpoch isa DataType
        @test SatelliteSimFoundation.CartesianState isa DataType
        include(joinpath(@__DIR__, "foundation", "test_time_grid.jl"))
    end

    @testset "Orbit" begin
        include(joinpath(@__DIR__, "orbit", "test_walker.jl"))
        include(joinpath(@__DIR__, "orbit", "test_ephemeris.jl"))
    end

    @testset "Link" begin
        include(joinpath(@__DIR__, "link", "test_gsl.jl"))
        include(joinpath(@__DIR__, "test_isl_constraints.jl"))
    end

    @testset "Net" begin
        include(joinpath(@__DIR__, "test_topology_strategies.jl"))
        include(joinpath(@__DIR__, "test_topology_metrics.jl"))
        include(joinpath(@__DIR__, "net", "test_routing.jl"))
        include(joinpath(@__DIR__, "net", "test_core_routing_paths.jl"))
        include(joinpath(@__DIR__, "test_cgr.jl"))
    end

    @testset "Traffic" begin
        include(joinpath(@__DIR__, "traffic", "test_aon.jl"))
        include(joinpath(@__DIR__, "traffic", "test_traffic_bridge.jl"))
    end

    @testset "Lab" begin
        include(joinpath(@__DIR__, "lab", "test_ground_traffic_precomposed.jl"))
    end

    @testset "AI" begin
        include(joinpath(@__DIR__, "ai", "runtests.jl"))
    end

    @testset "Metrics" begin
        include(joinpath(@__DIR__, "test_metrics.jl"))
    end

    @testset "Optimization" begin
        if RUN_SLOW
            include(joinpath(@__DIR__, "test_end_to_end_gradient.jl"))
        else
            @info "Optimization testset 跳过（设 SATSIM_RUN_SLOW=1 启用）"
        end
    end

    @testset "Security" begin
        include(joinpath(@__DIR__, "test_security.jl"))
        include(joinpath(@__DIR__, "test_security_p1.jl"))
    end

    @testset "Integration" begin
        include(joinpath(@__DIR__, "integration", "test_e2e.jl"))
    end

    @testset "Viz" begin
        include(joinpath(@__DIR__, "viz", "test_viz.jl"))
    end

    @testset "CLI" begin
        include(joinpath(@__DIR__, "cli", "test_cli.jl"))
    end
end

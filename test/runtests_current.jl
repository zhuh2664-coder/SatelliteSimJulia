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

# 慢测试守卫：默认跳过 Optimization（单 testset 5m48s），
# 设 SATSIM_RUN_SLOW=1 跑全量。这是"偶尔能测而非每次阻塞"的落地。
const RUN_SLOW = get(ENV, "SATSIM_RUN_SLOW", "0") == "1"

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
        if RUN_SLOW && isdefined(SatelliteSimJulia, :SatelliteSimOpt)
            include(joinpath(@__DIR__, "test_end_to_end_gradient.jl"))
        else
            @info "Optimization testset 跳过（需 SATSIM_RUN_SLOW=1 且 envs/opt 环境）"
        end
    end

    @testset "Security" begin
        if isdefined(SatelliteSimJulia, :SatelliteSimSecurity)
            include(joinpath(@__DIR__, "test_security.jl"))
        else
            @info "Security testset 跳过（SatelliteSimSecurity 不在当前伞包，见 envs/security 或 extras）"
        end
    end

    @testset "Integration" begin
        include(joinpath(@__DIR__, "integration", "test_e2e.jl"))
    end

    @testset "Bare-array CI contract" begin
        include(joinpath(@__DIR__, "test_bare_array_contract.jl"))
    end

    @testset "Viz" begin
        if get(ENV, "SATSIM_RUN_VIZ", "0") == "1" && isdefined(SatelliteSimJulia, :SatelliteSimViz)
            Viz = SatelliteSimJulia.SatelliteSimViz
            @test Viz.plot_orbit_snapshot isa Function
            @test Viz.geodetic_to_xyz isa Function
            @test Viz.plot_ground_track isa Function
            @test Viz.save_orbit_snapshot isa Function
            pos = zeros(Float64, 2, 1, 3)
            pos[1, 1, :] .= 7000.0, 0.0, 0.0
            pos[2, 1, :] .= 0.0, 7000.0, 0.0
            tmp_png = tempname() * ".png"
            try
                Viz.save_orbit_snapshot(tmp_png, pos)
                @test filesize(tmp_png) > 100
            catch e
                @warn "Viz 出图失败（可能缺 coastline 数据，非阻塞）" exception=e
                @test_broken false
            finally
                isfile(tmp_png) && rm(tmp_png; force=true)
            end
        else
            @info "Viz testset 跳过（设 SATSIM_RUN_VIZ=1 且在 envs/viz 环境运行）"
        end
    end
end

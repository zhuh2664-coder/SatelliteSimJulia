# SatelliteSimJulia 测试入口
#
# 默认走活跃 API 低成本套件；完整当前套件见 runtests_current.jl。
# 遗留巨型测试套件见 test/runtests_legacy.jl（需 SATSIM_RUN_LEGACY=1）。
push!(LOAD_PATH, "@stdlib")

using SatelliteSimJulia
using Test

const HAS_GLMAKIE = try
    @eval import GLMakie
    true
catch
    false
end

const RUN_LEGACY_TESTS = get(ENV, "SATSIM_RUN_LEGACY", "0") == "1"
const RUN_CURRENT_SUITE = get(ENV, "SATSIM_RUN_CURRENT", "0") == "1"

@testset "SatelliteSimJulia bootstrap" begin
    @test isdefined(SatelliteSimJulia, :supports_orbit_elements)
    @test isdefined(SatelliteSimJulia, :propagate_satellite)
    @test isdefined(SatelliteSimJulia, :EarthFixedNodePropagator)
    @test isdefined(SatelliteSimJulia, :EarthFixedOrbitElementSet)
    @test isdefined(SatelliteSimJulia, :ecef_to_geodetic)
    @test AbstractPropagator isa DataType
    @test AbstractOrbitElementSet isa DataType
    @test AbstractConstellationBuilder isa DataType

    struct FixturePropagator <: AbstractPropagator end
    SatelliteSimJulia.supports_orbit_elements(
        ::FixturePropagator,
        ::DesignOrbitElementSet,
    ) = true
    @test supports_orbit_elements(FixturePropagator(), DesignOrbitElementSet(altitude_km=550, inclination_deg=53))
end

# 活跃 API 独立测试（低成本）
include(joinpath(@__DIR__, "test_metrics.jl"))
include(joinpath(@__DIR__, "test_topology_strategies.jl"))
include(joinpath(@__DIR__, "test_intent_closure.jl"))
include(joinpath(@__DIR__, "test_precomposed_fixes.jl"))
include(joinpath(@__DIR__, "test_routing_graph.jl"))
include(joinpath(@__DIR__, "test_access_bounds.jl"))

if isdefined(SatelliteSimJulia, :SatelliteSimOpt)
    include(joinpath(@__DIR__, "test_opt_routing.jl"))
else
    @info "Opt routing tests 跳过（SatelliteSimOpt 不在伞包；见 envs/opt）"
end
if isdefined(SatelliteSimJulia, :SatelliteSimSecurity)
    include(joinpath(@__DIR__, "test_security.jl"))
    include(joinpath(@__DIR__, "test_security_p1.jl"))
else
    @info "Security tests 跳过（SatelliteSimSecurity 不在伞包；见 envs/security + test/runtests_security.jl）"
end

if RUN_CURRENT_SUITE
    @info "SATSIM_RUN_CURRENT=1：运行 runtests_current.jl"
    include(joinpath(@__DIR__, "runtests_current.jl"))
end

if RUN_LEGACY_TESTS
    @warn "SATSIM_RUN_LEGACY=1：运行遗留测试套件（大量 archive API，可能失败）"
    include(joinpath(@__DIR__, "runtests_legacy.jl"))
end

if HAS_GLMAKIE
    @testset "makie optional" begin
        @test true
    end
end

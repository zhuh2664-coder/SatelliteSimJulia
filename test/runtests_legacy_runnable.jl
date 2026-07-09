# 遗留测试中已与活跃 API 对齐的可运行子集。
# 用法：SATSIM_RUN_LEGACY=1 julia --project=. test/runtests_legacy_runnable.jl

push!(LOAD_PATH, "@stdlib")
using Test

if get(ENV, "SATSIM_RUN_LEGACY", "0") != "1"
    println(stderr, "[runtests_legacy_runnable] 需 SATSIM_RUN_LEGACY=1")
    @testset "legacy runnable (skipped)" begin
        @test_skip "SATSIM_RUN_LEGACY!=1"
    end
else
    using SatelliteSimJulia
    using Dates
    using SatelliteSimFoundation: TimeUTC, SatelliteConfig
    import LinearAlgebra

    @testset "legacy runnable: package skeleton" begin
        @test AbstractConstellationBuilder isa DataType
        @test AbstractFrameTransform isa DataType
        @test AbstractOrbitElementSet isa DataType
        @test AbstractPropagator isa DataType
    end

    @testset "legacy runnable: time model" begin
        epoch = SimulationEpoch(DateTime(2026, 1, 1), TimeUTC)
        grid = SimulationTimeGrid(epoch, 10, 3)
        @test time_count(grid) == 5
        @test timeslot_offsets(grid) == [0, 3, 6, 9, 10]
    end

    @testset "legacy runnable: orbit entities" begin
        design = DesignOrbitElementSet(altitude_km=550, inclination_deg=53, raan_deg=10)
        sat = Satellite(id=1, orbit=design, config=SatelliteConfig())
        @test sat.id == 1
        @test design.raan_deg == 10.0
        earth_fixed = EarthFixedOrbitElementSet(550.0, 53.0, 10.0, 0.0, SourceMetadata("ef"))
        @test earth_fixed.altitude_km == 550.0
    end

    include(joinpath(@__DIR__, "test_metrics.jl"))
    include(joinpath(@__DIR__, "test_topology_strategies.jl"))
end

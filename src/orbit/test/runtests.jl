# src/orbit/test/runtests.jl — SatelliteSimOrbit 独立 smoke 测试
#
# 轨道层：Walker 星座生成 + 传播器（TwoBody/J2/J4/SGP4）→ ECEF 位置矩阵。
# 依赖 Foundation。测试用最小星座(T=6,P=2)，秒级完成。

using SatelliteSimOrbit
using SatelliteSimFoundation
using Dates
using SatelliteSimBackends
using Test

struct ContractBackend <: SatelliteSimBackends.AbstractOrbitBackend end

SatelliteSimBackends.propagate_orbit(::ContractBackend, elements, times; kwargs...) =
    SatelliteSimBackends.OrbitResult(
        reshape(collect(1.0:(length(elements) * length(times) * 3)), length(elements), length(times), 3),
        Dict{String,Any}("backend" => "contract-test"),
    )

@testset "SatelliteSimOrbit" begin

    @testset "Walker 星座生成" begin
        elems = generate_walker_delta(; T=6, P=2, F=0, alt_km=550.0, inc_deg=53.0)
        @test length(elems) == 6
        # 每个元素应是 Keplerian 元素
        @test all(e -> e isa typeof(elems[1]), elems)
    end

    @testset "TwoBody 传播 → ECEF 位置矩阵" begin
        elems = generate_walker_delta(; T=6, P=2, F=0, alt_km=550.0, inc_deg=53.0)
        pos = propagate_to_ecef(elems, [0.0, 60.0, 120.0]; propagator=TwoBodyPropagator())
        @test size(pos) == (6, 3, 3)   # N×T×3
        # 位置应在合理地球半径范围（550km 高度 → ~6921km 半径）
        @test all(isfinite, pos)
        norms = [sqrt(sum(pos[i,t,:].^2)) for i in 1:6, t in 1:3]
        @test all(n -> 6800.0 < n < 7100.0, norms)
    end

    @testset "设计星座入口 → 标准时间网格" begin
        elems = generate_walker_delta(; T=6, P=2, F=0, alt_km=550.0, inc_deg=53.0)
        grid = SimulationTimeGrid(SimulationEpoch(DateTime(2024, 1, 1)), 120, 60)
        pos = propagate_to_ecef(elems, grid; propagator=J2Propagator())
        @test size(pos) == (6, 3, 3)
        @test all(isfinite, pos)
    end

    @testset "真实 TLE 入口 → SGP4" begin
        tle = TLEOrbitElementSet(
            "VANGUARD 1",
            "1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753",
            "2 00005  34.2682 331.5174 1859667 331.7664  19.3264 10.82419157413667",
        )
        grid = SimulationTimeGrid(SimulationEpoch(DateTime(2000, 6, 27, 18, 50, 19)), 120, 60)
        pos = propagate_to_ecef([tle], grid; verify_checksum=false)
        @test size(pos) == (1, 3, 3)
        @test all(isfinite, pos)
    end

    @testset "传播器类型" begin
        @test TwoBodyPropagator() isa AbstractKeplerianPropagator
        @test J2Propagator() isa AbstractKeplerianPropagator
        @test J4Propagator() isa AbstractKeplerianPropagator
    end

    @testset "访问器函数" begin
        elems = generate_walker_delta(; T=6, P=2, F=0, alt_km=550.0, inc_deg=53.0)
        pos = propagate_to_ecef(elems, [0.0, 60.0]; propagator=TwoBodyPropagator())
        @test n_satellites(pos) == 6
        @test n_timesteps(pos) == 2
        @test size(positions_at_last(pos)) == (6, 3)
        @test size(position_at_instant(pos, 1)) == (6, 3)
    end
end

@testset "Optional backend dispatch preserves the ECEF array contract" begin
    elements = [:one, :two]
    times = 0:10:20
    result = propagate_with_backend(ContractBackend(), elements, times)
    positions = propagate_to_ecef(ContractBackend(), elements, times)

    @test size(result.positions_ecef_km) == (2, 3, 3)
    @test positions == result.positions_ecef_km
    @test n_satellites(positions) == 2
    @test n_timesteps(positions) == 3
end

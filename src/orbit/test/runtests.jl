# src/orbit/test/runtests.jl — SatelliteSimOrbit 独立 smoke 测试
#
# 轨道层：Walker 星座生成 + 传播器（TwoBody/J2/J4/SGP4）→ ECEF 位置矩阵。
# 依赖 Foundation。测试用最小星座(T=6,P=2)，秒级完成。

using SatelliteSimOrbit
using SatelliteSimFoundation
using Test

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

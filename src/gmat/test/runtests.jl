# src/gmat/test/runtests.jl — GMAT 独立 smoke 测试
#
# GMAT 风格航天动力学引擎：力模型 + 积分器 + 任务命令。
# 依赖 Foundation。测试只验证类型/函数存在与构造，不猜复杂积分接口。

using GMAT
using SatelliteSimFoundation
using Test

@testset "GMAT" begin

    @testset "航天器构造" begin
        # Spacecraft 是物理参数（质量/面积/系数），非状态向量
        sc = Spacecraft(; mass_dry=500.0, mass_fuel=500.0, area_drag_m2=2.0,
                        area_srp_m2=2.0, cd=2.2, cr=1.3)
        @test sc isa Spacecraft
        @test mass(sc) == 1000.0   # mass_dry + mass_fuel
    end

    @testset "力模型" begin
        @test GravityField isa DataType
        grav = GravityField(; degree=4)
        @test grav isa GravityField
        @test ThirdBody isa DataType
        @test AtmosphericDrag isa DataType
        @test SolarRadiationPressure isa DataType
        # 常量
        @test SUN_MU > 1e19
        @test MOON_MU > 4000.0
        # 力模型组合
        fm = ForceModel([grav])
        @test fm isa ForceModel
    end

    @testset "积分器" begin
        @test PrinceDormand78 isa DataType
        @test RungeKutta89 isa DataType
        integ = PrinceDormand78()
        @test integ isa AbstractIntegrator
        @test integrate isa Function
        @test propagate isa Function
    end

    @testset "任务命令" begin
        @test PropagateCommand isa DataType
        @test Maneuver isa DataType
        @test Target isa DataType
        @test execute isa Function
        @test run_mission isa Function
        @test MissionState isa DataType
    end
end

using SatelliteSimJulia
using ForwardDiff
using Test

@testset "Differentiable Propagator" begin
    
    @testset "Smooth approximations" begin
        @test smooth_step(0.0) ≈ 0.5
        @test smooth_step(10.0) > 0.99
        @test smooth_step(-10.0) < 0.01
        @test smooth_abs(0.0) < 0.5
        @test smooth_abs(5.0) ≈ 5.0 atol=0.1
    end
    
    @testset "ForwardDiff compatibility" begin
        f(x) = smooth_step(x[1]) + smooth_abs(x[2])
        grad = ForwardDiff.gradient(f, [1.0, -2.0])
        @test length(grad) == 2
        @test all(isfinite.(grad))
    end
    
    @testset "Gradient computation" begin
        dummy_propagate(params, t) = [params[1]*cos(t), params[2]*sin(t)]
        loss(state) = sum(state.^2)
        params = [1.0, 2.0]
        grad = gradient_orbit_params(dummy_propagate, loss, params, 0.5)
        @test length(grad) == 2
        @test all(isfinite.(grad))
    end
    
    @testset "Jacobian computation" begin
        dummy_propagate(params, t) = [params[1]*cos(t), params[2]*sin(t)]
        result = propagate_diff(dummy_propagate, [1.0, 2.0], 0.5)
        @test size(result.jacobian) == (2, 2)
        @test all(isfinite.(result.jacobian))
    end
    
end

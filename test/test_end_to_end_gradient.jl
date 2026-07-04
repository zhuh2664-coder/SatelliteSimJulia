using Test
using SatelliteSimOpt

@testset "end-to-end differentiable architecture" begin
    report = end_to_end_gradient_report()

    @test isfinite(report.loss)
    @test report.n_params == 21
    @test isfinite(report.grad_forward_norm)
    @test isfinite(report.grad_reverse_norm)
    @test isfinite(report.grad_finite_difference_norm)
    @test report.grad_forward_norm > 0
    @test report.finite_forward
    @test report.finite_reverse
    @test report.finite_fd
    @test report.max_relerr_forward_vs_fd < 1e-3
    @test report.max_relerr_reverse_vs_forward < 1e-6
end

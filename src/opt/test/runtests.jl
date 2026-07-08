using SatelliteSimOpt
using Test

const RUN_SLOW = get(ENV, "SATSIM_RUN_SLOW", "0") == "1"

@testset "SatelliteSimOpt" begin
    @testset "smooth approximations" begin
        @test smooth_step(0.0) ≈ 0.5 atol = 1e-12
        @test smooth_step(10.0) > 0.99
        @test smooth_step(-10.0) < 0.01
        @test smooth_abs(0.0) > 0.0
    end

    @testset "gradient fixture" begin
        tles = fixture_gradient_tles()
        @test length(tles) >= 1
    end

    @testset "soft route loss contract" begin
        flat_positions = [
            0.0, 0.0, 0.0,
            1000.0, 0.0, 0.0,
            2000.0, 0.0, 0.0,
        ]
        loss = soft_route_loss(flat_positions)
        @test isfinite(loss)
        @test loss > 0
    end

    @testset "end-to-end gradient report" begin
        if RUN_SLOW
            report = end_to_end_gradient_report()
            @test report isa EndToEndGradientReport
            @test report.n_params > 0
            @test isfinite(report.loss)
            @test report.finite_forward
            @test report.finite_reverse
            @test report.finite_fd
            @test report.grad_forward_norm > 0
            @test report.grad_reverse_norm > 0
            @test report.grad_finite_difference_norm > 0
            @test report.max_relerr_forward_vs_fd < 1e-3
            @test report.max_relerr_reverse_vs_forward < 1e-10
        else
            @info "end-to-end gradient report skipped; set SATSIM_RUN_SLOW=1 to enable"
            @test EndToEndGradientConfig() isa EndToEndGradientConfig
        end
    end
end

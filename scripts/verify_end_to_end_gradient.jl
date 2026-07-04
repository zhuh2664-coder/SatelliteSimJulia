#!/usr/bin/env julia

using SatelliteSimOpt

function main()::Nothing
    report = end_to_end_gradient_report()

    println("END_TO_END_GRADIENT_SUCCESS")
    println("chain=TLE_params -> SatelliteToolboxSgp4.sgp4! -> ISL distances/delays -> soft route loss")
    println("loss=$(report.loss)")
    println("n_params=$(report.n_params)")
    println("grad_forward_norm=$(report.grad_forward_norm)")
    println("grad_reverse_norm=$(report.grad_reverse_norm)")
    println("grad_finite_difference_norm=$(report.grad_finite_difference_norm)")
    println("max_relerr_forward_vs_fd=$(report.max_relerr_forward_vs_fd)")
    println("max_relerr_reverse_vs_forward=$(report.max_relerr_reverse_vs_forward)")
    println("finite_forward=$(report.finite_forward)")
    println("finite_reverse=$(report.finite_reverse)")
    println("finite_fd=$(report.finite_fd)")

    if !(report.finite_forward && report.finite_reverse && report.finite_fd)
        error("non-finite gradient detected")
    end
    if report.grad_forward_norm <= 0
        error("zero ForwardDiff gradient")
    end
    if report.max_relerr_forward_vs_fd > 1e-3
        error("ForwardDiff gradient disagrees with finite differences")
    end
    if report.max_relerr_reverse_vs_forward > 1e-6
        error("Zygote gradient disagrees with ForwardDiff")
    end
    return nothing
end

main()

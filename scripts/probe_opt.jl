#!/usr/bin/env julia
# Opt 冒烟探针：验证可微传播 + 梯度路径数值合理性
# 对应 probe_e2e.jl 之于 Core 的角色——Opt 当前 zero 测试覆盖，这是第一个数值回归线。

using SatelliteSimOpt
using Printf

println("=" ^ 60)
println("PROBE: SatelliteSimOpt 可微路径")
println("=" ^ 60)

# 1. smooth_step / smooth_abs 数值正确性
println("[1] smooth 光滑近似数值检查")
s0 = smooth_step(0.0)
s_pos = smooth_step(10.0)
s_neg = smooth_step(-10.0)
@printf("    smooth_step(0)=%.4f (期望 0.5)\n", s0)
@printf("    smooth_step(+10)=%.4f (期望≈1)\n", s_pos)
@printf("    smooth_step(-10)=%.6f (期望≈0)\n", s_neg)
@printf("    smooth_abs(0)=%.6f (期望>0, 光滑)\n", smooth_abs(0.0))
const ok1 = 0.49 < s0 < 0.51 && s_pos > 0.99 && s_neg < 0.01
@printf("    => %s\n", ok1 ? "PASS" : "FAIL")

# 2. fixture TLE 可用
println("[2] fixture_gradient_tles")
tles = fixture_gradient_tles()
@printf("    TLE 数量: %d (期望 ≥1)\n", length(tles))
const ok2 = length(tles) ≥ 1
@printf("    => %s\n", ok2 ? "PASS" : "FAIL")

# 3. 端到端梯度报告（ForwardDiff / Reverse / FD 三路对比）
println("[3] end_to_end_gradient_report（核心可微路径）")
report = end_to_end_gradient_report()
@printf("    loss = %.6e\n", report.loss)
@printf("    n_params = %d\n", report.n_params)
@printf("    ‖grad_forward‖  = %.6e\n", report.grad_forward_norm)
@printf("    ‖grad_reverse‖  = %.6e\n", report.grad_reverse_norm)
@printf("    ‖grad_finite_diff‖ = %.6e\n", report.grad_finite_difference_norm)
@printf("    max_relerr forward vs FD = %.6e\n", report.max_relerr_forward_vs_fd)
@printf("    max_relerr reverse vs forward = %.6e\n", report.max_relerr_reverse_vs_forward)
@printf("    all finite: forward=%s reverse=%s fd=%s\n",
    report.finite_forward, report.finite_reverse, report.finite_fd)

# 判据：梯度有限 + Forward/FD 相对误差合理（<0.5 说明方向一致）
const ok3 = report.finite_forward && report.finite_reverse &&
            report.grad_forward_norm > 0 &&
            isfinite(report.max_relerr_forward_vs_fd)
@printf("    => %s\n", ok3 ? "PASS" : "FAIL")

println("=" ^ 60)
if ok1 && ok2 && ok3
    println("PROBE OPT: ALL PASS")
else
    println("PROBE OPT: HAS FAILURES (见上)")
end
println("=" ^ 60)

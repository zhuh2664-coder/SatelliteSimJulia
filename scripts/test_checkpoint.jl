#!/usr/bin/env julia
using SatelliteSimLab
config = ExperimentConfig(name="cp_test",
    constellation_params=Dict(:T=>66.0,:P=>6.0,:F=>2.0,:alt_km=>780.0,:inc_deg=>86.4),
    tspan=[0.0, 60.0])
result = run_with_checkpoints(config)
cps = list_checkpoints("cp_test")
println("检查点数: ", length(cps))
for cp in cps
    println("  step=", cp.step, " time=", round(cp.duration_s, digits=3), "s",
            " conn=", cp.metrics_snapshot["connectivity_ratio"])
end
println("P1 验证完成")

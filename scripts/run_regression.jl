#!/usr/bin/env julia
# 一键回归：项目所有数值/功能回归线的统一入口
#
# 用法：julia --project=. scripts/run_regression.jl
#
# 回归线清单（每条独立可跑，本脚本逐条执行并汇总）：
#   1. quick_validate.jl        — 各子包加载 + 5 项功能检查
#   2. integration_test.jl      — Core/Net/Lab 类型与拓扑集成
#   3. smoke_core_net_lab_experiment.jl — 完整 Lab 实验（Walker→传播→ISL/GSL→路由）
#   4. probe_e2e.jl             — Core 裸数组主路径数值（66/6 ISL + 路由连通性）
#   5. probe_opt.jl             — Opt 可微路径数值（三路梯度一致性）
#
# 任一失败 → 退出码 1，全绿 → 退出码 0。

using Printf

const SCRIPTS = [
    ("quick_validate",        "scripts/quick_validate.jl"),
    ("integration_test",      "scripts/integration_test.jl"),
    ("smoke_experiment",      "scripts/smoke_core_net_lab_experiment.jl"),
    ("probe_e2e (Core 主路径)", "scripts/probe_e2e.jl"),
    ("probe_opt (Opt 可微路径)", "scripts/probe_opt.jl"),
]

results = Tuple{String,Bool,String}[]  # (name, pass, marker)

println("=" ^ 64)
println("REGRESSION SUITE — SatelliteSimJulia")
println("=" ^ 64)

for (name, path) in SCRIPTS
    print(rpad("[● $name]", 36))
    flush(stdout)
    out = Pipe()
    err = Pipe()
    cmd = `julia --project=. $path`
    proc_success = false
    combined = ""
    try
        proc = run(pipeline(cmd, stdout=out, stderr=err))
        close(out.in)
        close(err.in)
        combined = String(read(out)) * String(read(err))
        proc_success = success(proc)
    catch ex
        proc_success = false
        try
            combined = String(read(out)) * String(read(err))
        catch
        end
    end

    if proc_success
        # 提取成功标记
        marker = ""
        occursin("ALL TESTS PASSED", combined)   && (marker = "ALL TESTS PASSED")
        occursin("Package hierarchy validated", combined) && isempty(marker) && (marker = "hierarchy OK")
        occursin("SMOKE SUCCESS", combined)       && isempty(marker) && (marker = "SMOKE SUCCESS")
        occursin("PROBE OPT: ALL PASS", combined) && isempty(marker) && (marker = "OPT PASS")
        occursin("PROBE-2 DONE", combined)        && isempty(marker) && (marker = "E2E PASS")
        isempty(marker) && (marker = "exit 0")
        println("✓ PASS  ($marker)")
        push!(results, (name, true, marker))
    else
        # 失败：打印最后 5 行错误
        println("✗ FAIL")
        for line in split(combined, '\n')[max(1,end-4):end]
            isempty(line) || println("      ", line)
        end
        push!(results, (name, false, ""))
    end
end

println("=" ^ 64)
npass = count(r -> r[2], results)
nfail = length(results) - npass
@printf("RESULT: %d/%d passed", npass, length(results))
nfail > 0 && @printf(", %d FAILED", nfail)
println()
println("=" ^ 64)

exit(nfail == 0 ? 0 : 1)

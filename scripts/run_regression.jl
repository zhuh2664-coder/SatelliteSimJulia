#!/usr/bin/env julia
# 一键回归：项目所有数值/功能回归线的统一入口
#
# 用法：julia --project=. scripts/run_regression.jl
#
# 默认只跑部署 smoke 需要的纯 Julia 回归线；耗时/外部环境检查通过环境变量启用：
#   SATSIM_RUN_PACKAGE_TESTS=1 julia --project=. scripts/run_regression.jl
#   SATSIM_RUN_PLATFORM=1      julia --project=. scripts/run_regression.jl
#   SATSIM_RUN_K8S=1           julia --project=. scripts/run_regression.jl
#
# 任一失败 → 退出码 1，全绿 → 退出码 0。

using Printf

const ROOT = normpath(joinpath(@__DIR__, ".."))

_script(path...) = joinpath(ROOT, path...)

jobs = Tuple{String,Cmd}[
    ("root_tests",             `julia --project=$ROOT $(_script("test", "runtests_current.jl"))`),
    ("quick_validate",         `julia --project=$ROOT $(_script("scripts", "quick_validate.jl"))`),
    ("integration_test",       `julia --project=$ROOT $(_script("scripts", "integration_test.jl"))`),
    ("smoke_experiment",       `julia --project=$ROOT $(_script("scripts", "smoke_core_net_lab_experiment.jl"))`),
    ("probe_e2e (Core 主路径)", `julia --project=$ROOT $(_script("scripts", "probe_e2e.jl"))`),
    ("probe_opt (Opt 可微路径)", `julia --project=$ROOT $(_script("scripts", "probe_opt.jl"))`),
]

if get(ENV, "SATSIM_RUN_PACKAGE_TESTS", "0") == "1"
    push!(jobs, ("package_tests", `julia --project=$ROOT $(_script("scripts", "package_tests.jl"))`))
end

if get(ENV, "SATSIM_RUN_PLATFORM", "0") == "1"
    push!(jobs, ("platform_local_smoke", `bash $(_script("platform", "scripts", "smoke_local.sh"))`))
end

if get(ENV, "SATSIM_RUN_K8S", "0") == "1"
    push!(jobs, ("platform_k8s_smoke", `bash $(_script("platform", "scripts", "smoke_k3s.sh"))`))
end

results = Tuple{String,Bool,String}[]  # (name, pass, marker)

function run_job(cmd::Cmd)
    output_path = tempname()
    proc_success = false
    combined = ""

    try
        open(output_path, "w") do io
            proc = run(pipeline(cmd, stdout=io, stderr=io))
            proc_success = success(proc)
        end
        combined = read(output_path, String)
    catch
        isfile(output_path) && (combined = read(output_path, String))
        proc_success = false
    finally
        isfile(output_path) && rm(output_path; force=true)
    end

    return proc_success, combined
end

println("=" ^ 64)
println("REGRESSION SUITE — SatelliteSimJulia")
println("=" ^ 64)

for (name, cmd) in jobs
    print(rpad("[● $name]", 36))
    flush(stdout)
    proc_success, combined = run_job(cmd)

    if proc_success
        marker = ""
        occursin("SatelliteSimJulia current test suite", combined) && (marker = "ROOT TESTS PASS")
        occursin("QUICK VALIDATE: ALL PASS", combined) && isempty(marker) && (marker = "QUICK PASS")
        occursin("ALL TESTS PASSED", combined) && isempty(marker) && (marker = "ALL TESTS PASSED")
        occursin("Package hierarchy validated", combined) && isempty(marker) && (marker = "hierarchy OK")
        occursin("SMOKE SUCCESS", combined) && isempty(marker) && (marker = "SMOKE SUCCESS")
        occursin("PROBE OPT: ALL PASS", combined) && isempty(marker) && (marker = "OPT PASS")
        occursin("PACKAGE RESULT: 9/9 passed", combined) && isempty(marker) && (marker = "PACKAGE TESTS PASS")
        occursin("PROBE-2 DONE", combined) && isempty(marker) && (marker = "E2E PASS")
        occursin("SMOKE LOCAL: ALL PASS", combined) && isempty(marker) && (marker = "PLATFORM LOCAL PASS")
        occursin("SMOKE K3S: ALL PASS", combined) && isempty(marker) && (marker = "K8S PASS")
        isempty(marker) && (marker = "exit 0")
        println("✓ PASS  ($marker)")
        push!(results, (name, true, marker))
    else
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

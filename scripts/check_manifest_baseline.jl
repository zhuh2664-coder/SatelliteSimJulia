#!/usr/bin/env julia
# 对比各环境 Manifest 包数量与基线上限（Phase 1'）。

using JSON
using Pkg

const BASELINE_PATH = joinpath(@__DIR__, "manifest_baseline.json")

function count_packages(project::AbstractString)
    Pkg.activate(project)
    n_direct = count(p -> p.is_direct_dep, values(Pkg.dependencies()))
    n_total = length(Pkg.dependencies())
    return n_direct, n_total
end

function main()
    root = abspath(joinpath(@__DIR__, ".."))
    cd(root)

    isfile(BASELINE_PATH) || error("missing baseline file: $BASELINE_PATH")

    baseline = JSON.parsefile(BASELINE_PATH)
    failed = false

    for (env, limits) in baseline
        project = env == "root" ? "." : joinpath("envs", env)
        isdir(project) || isdir(joinpath(root, project)) || continue

        _, n_total = count_packages(project)
        max_total = get(limits, "max_total", nothing)
        min_total = get(limits, "min_total", nothing)

        ok = true
        if max_total !== nothing && n_total > max_total
            ok = false
            println("FAIL $project total_packages=$n_total > max_total=$max_total")
        elseif min_total !== nothing && n_total < min_total
            ok = false
            println("FAIL $project total_packages=$n_total < min_total=$min_total")
        else
            println("OK   $project total_packages=$n_total")
        end
        failed |= !ok
    end

    failed && exit(1)
    println("manifest baseline check: PASS")
end

main()

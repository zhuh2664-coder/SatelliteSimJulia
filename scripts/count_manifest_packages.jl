#!/usr/bin/env julia
# 统计指定 --project 环境的 Manifest 包数量。

using Pkg

function main()
    project = get(ENV, "JULIA_PROJECT", ".")
    Pkg.activate(project)
    n_direct = count(p -> p.is_direct_dep, values(Pkg.dependencies()))
    n_total = length(Pkg.dependencies())
    println("project: ", project)
    println("direct_deps: ", n_direct)
    println("total_packages: ", n_total)
end

main()

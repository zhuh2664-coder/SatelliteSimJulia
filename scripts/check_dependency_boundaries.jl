#!/usr/bin/env julia
# Phase 0' 依赖边界检查：主链 Project.toml 不得声明重型可选依赖。

const FORBIDDEN_IN_CORE = Set([
    "Flux", "Lux", "Zygote", "Enzyme", "Optimisers",
    "CairoMakie", "Makie", "GeoMakie", "GLMakie",
    "OrdinaryDiffEq", "DiffEqBase", "SciMLBase",
    "BenchmarkTools", "Revise", "PackageCompiler",
])

const CORE_PROJECT_FILES = [
    "Project.toml",
    "envs/core/Project.toml",
    "envs/sim/Project.toml",
    "src/foundation/Project.toml",
    "src/orbit/Project.toml",
    "src/link/Project.toml",
    "src/core/Project.toml",
    "src/net/Project.toml",
    "src/metrics/Project.toml",
    "src/traffic/Project.toml",
    "src/lab/Project.toml",
]

const ROOT_FORBIDDEN_DEPS = Set([
    "Flux", "Lux", "Zygote", "Enzyme", "Optimisers", "ForwardDiff",
    "CairoMakie", "Makie", "GeoMakie", "OrdinaryDiffEq",
    "SatelliteSimOpt", "SatelliteSimViz", "SatelliteSimDistributed",
    "GMAT", "BenchmarkTools", "SatelliteSimSecurity",
])

function parse_dep_names(path::AbstractString)
    isfile(path) || return String[]
    lines = readlines(path)
    in_deps = false
    names = String[]
    for line in lines
        s = strip(line)
        if s == "[deps]"
            in_deps = true
            continue
        end
        if startswith(s, "[") && s != "[deps]"
            in_deps = false
            continue
        end
        if in_deps && !isempty(s) && !startswith(s, "#")
            m = match(r"^([A-Za-z][A-Za-z0-9_]*)", s)
            m !== nothing && push!(names, m.captures[1])
        end
    end
    return names
end

function check_file(path::AbstractString, forbidden::Set{String})
    violations = String[]
    for name in parse_dep_names(path)
        if name in forbidden
            push!(violations, name)
        end
    end
    return violations
end

function main()
    root = abspath(joinpath(@__DIR__, ".."))
    cd(root)

    failed = false

    root_violations = check_file("Project.toml", ROOT_FORBIDDEN_DEPS)
    if !isempty(root_violations)
        failed = true
        println("FAIL root Project.toml forbidden deps: ", join(root_violations, ", "))
    else
        println("OK   root Project.toml")
    end

    for rel in CORE_PROJECT_FILES
        path = joinpath(root, rel)
        if !isfile(path)
            continue
        end
        v = check_file(path, FORBIDDEN_IN_CORE)
        if !isempty(v)
            failed = true
            println("FAIL $rel forbidden deps: ", join(v, ", "))
        else
            println("OK   $rel")
        end
    end

    umbrella = read(joinpath(root, "src", "SatelliteSimJulia.jl"), String)
    umbrella_ok = true
    for sym in ("SatelliteSimOpt", "SatelliteSimViz", "SatelliteSimDistributed", "SatelliteSimSecurity")
        if occursin("@reexport using $sym", umbrella)
            failed = true
            umbrella_ok = false
            println("FAIL SatelliteSimJulia.jl still reexports $sym")
        end
    end
    umbrella_ok && println("OK   SatelliteSimJulia.jl umbrella (no Opt/Viz/Distributed/Security reexport)")

    if failed
        exit(1)
    end
    println("dependency boundary check: PASS")
end

main()

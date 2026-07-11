#!/usr/bin/env julia

using TOML

const ROOT = normpath(joinpath(@__DIR__, ".."))
const CONFIG = TOML.parsefile(joinpath(ROOT, "config", "manifest-baseline.toml"))
const MAX_GROWTH = Float64(CONFIG["max_growth_percent"])
const STRICT = get(ENV, "SATSIM_MANIFEST_STRICT", "0") == "1"

function package_count(path::String)::Int
    manifest = TOML.parsefile(path)
    deps = get(manifest, "deps", Dict{String,Any}())
    return length(deps)
end

violations = String[]
for (name, spec_any) in sort(collect(CONFIG["environments"]); by=first)
    spec = Dict{String,Any}(spec_any)
    path = joinpath(ROOT, String(spec["path"]))
    if !isfile(path)
        println("MANIFEST ", name, ": SKIP (", relpath(path, ROOT), " missing)")
        continue
    end
    baseline = Int(spec["packages"])
    current = package_count(path)
    limit = floor(Int, baseline * (1 + MAX_GROWTH / 100))
    status = current <= limit ? "PASS" : "WARN"
    println("MANIFEST ", name, ": ", status, " current=", current, " baseline=", baseline, " limit=", limit)
    current <= limit || push!(violations, "$name grew from $baseline to $current packages (limit $limit)")
end

if !isempty(violations) && STRICT
    foreach(message -> println(stderr, "  - ", message), violations)
    exit(1)
end
println(isempty(violations) ? "MANIFEST BASELINE: PASS" : "MANIFEST BASELINE: WARN")

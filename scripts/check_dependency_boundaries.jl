#!/usr/bin/env julia

using TOML

const ROOT = normpath(joinpath(@__DIR__, ".."))
const LOCAL_PACKAGES = Set([
    "SatelliteSimFoundation", "SatelliteSimOrbit", "SatelliteSimLink",
    "SatelliteSimMetrics", "SatelliteSimNet", "SatelliteSimTraffic",
    "SatelliteSimCore", "SatelliteSimLab", "SatelliteSimSecurity",
    "SatelliteSimOpt", "GMAT",
])

const PACKAGE_DIRS = Dict(
    "SatelliteSimFoundation" => "foundation",
    "SatelliteSimOrbit" => "orbit",
    "SatelliteSimLink" => "link",
    "SatelliteSimMetrics" => "metrics",
    "SatelliteSimNet" => "net",
    "SatelliteSimTraffic" => "traffic",
    "SatelliteSimCore" => "core",
    "SatelliteSimLab" => "lab",
    "SatelliteSimSecurity" => "security",
    "SatelliteSimOpt" => "opt",
    "GMAT" => "gmat",
)

const ALLOWED_LOCAL_DEPS = Dict(
    "SatelliteSimFoundation" => Set{String}(),
    "SatelliteSimOrbit" => Set(["SatelliteSimFoundation"]),
    "SatelliteSimLink" => Set(["SatelliteSimFoundation", "SatelliteSimOrbit"]),
    "SatelliteSimMetrics" => Set(["SatelliteSimFoundation"]),
    "SatelliteSimNet" => Set(["SatelliteSimFoundation", "SatelliteSimLink"]),
    "SatelliteSimTraffic" => Set(["SatelliteSimFoundation", "SatelliteSimLink", "SatelliteSimNet"]),
    "SatelliteSimCore" => Set(["SatelliteSimFoundation", "SatelliteSimOrbit", "SatelliteSimLink", "SatelliteSimMetrics"]),
    "SatelliteSimLab" => Set([
        "SatelliteSimFoundation", "SatelliteSimOrbit", "SatelliteSimLink",
        "SatelliteSimMetrics", "SatelliteSimNet", "SatelliteSimTraffic", "SatelliteSimCore",
    ]),
    "SatelliteSimSecurity" => Set([
        "SatelliteSimFoundation", "SatelliteSimLink", "SatelliteSimMetrics",
        "SatelliteSimNet", "SatelliteSimTraffic",
    ]),
    "SatelliteSimOpt" => Set([
        "SatelliteSimFoundation", "SatelliteSimOrbit", "SatelliteSimLink", "SatelliteSimNet",
    ]),
    "GMAT" => Set(["SatelliteSimFoundation"]),
)

failures = String[]
for (package, dir) in sort(collect(PACKAGE_DIRS); by=first)
    project_path = joinpath(ROOT, "src", dir, "Project.toml")
    project = TOML.parsefile(project_path)
    deps = Set(String.(keys(get(project, "deps", Dict{String,Any}()))))
    local_deps = intersect(deps, LOCAL_PACKAGES)
    forbidden = setdiff(local_deps, ALLOWED_LOCAL_DEPS[package])
    isempty(forbidden) || push!(
        failures,
        "$package has forbidden local dependencies: $(join(sort(collect(forbidden)), ", "))",
    )

    sources = get(project, "sources", Dict{String,Any}())
    for dependency in local_deps
        haskey(sources, dependency) || push!(
            failures,
            "$package declares $dependency but has no local [sources] entry",
        )
    end
end

for (package, dir) in [
    "SatelliteSimNet" => "net",
    "SatelliteSimTraffic" => "traffic",
    "SatelliteSimSecurity" => "security",
    "SatelliteSimOpt" => "opt",
]
    deps = get(TOML.parsefile(joinpath(ROOT, "src", dir, "Project.toml")), "deps", Dict{String,Any}())
    haskey(deps, "SatelliteSimCore") && push!(failures, "$package must not depend on SatelliteSimCore")
end

if isempty(failures)
    println("DEPENDENCY BOUNDARIES: PASS")
else
    println(stderr, "DEPENDENCY BOUNDARIES: FAIL")
    foreach(message -> println(stderr, "  - ", message), failures)
    exit(1)
end

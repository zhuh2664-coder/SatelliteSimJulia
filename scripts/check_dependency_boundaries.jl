#!/usr/bin/env julia

using TOML

const ROOT = normpath(joinpath(@__DIR__, ".."))
const DEPENDENCY_SECTIONS = ("deps", "weakdeps", "extras")
const MAIN_CHAIN_ENVIRONMENTS = Set(["core", "sim"])
const LOCAL_PACKAGES = Set([
    "SatelliteSimFoundation", "SatelliteSimOrbit", "SatelliteSimLink",
    "SatelliteSimMetrics", "SatelliteSimNet", "SatelliteSimTraffic",
    "SatelliteSimCore", "SatelliteSimLab", "SatelliteSimSecurity",
    "SatelliteSimOpt", "GMAT",
    "SatelliteSimBackends", "SatelliteSimStubBackend", "SatelliteSimJuliaSpaceBackend",
    "SatelliteSimGPU",
    "PlatformRunner", "SatelliteSimPlatformStorage", "SatelliteSimPlatformScheduler",
    "SatelliteSimPlatformKubernetes", "SatelliteSimPlatformControl", "SatelliteSimPlatformBenchmarks",
])

const PACKAGE_PROJECTS = Dict(
    "SatelliteSimFoundation" => "src/foundation",
    "SatelliteSimOrbit" => "src/orbit",
    "SatelliteSimLink" => "src/link",
    "SatelliteSimMetrics" => "src/metrics",
    "SatelliteSimNet" => "src/net",
    "SatelliteSimTraffic" => "src/traffic",
    "SatelliteSimCore" => "src/core",
    "SatelliteSimLab" => "src/lab",
    "SatelliteSimSecurity" => "src/security",
    "SatelliteSimOpt" => "src/opt",
    "GMAT" => "src/gmat",
    "SatelliteSimBackends" => "packages/SatelliteSimBackends",
    "SatelliteSimStubBackend" => "packages/SatelliteSimStubBackend",
    "SatelliteSimJuliaSpaceBackend" => "packages/SatelliteSimJuliaSpaceBackend",
    "SatelliteSimGPU" => "packages/SatelliteSimGPU",
    "PlatformRunner" => "platform/runner",
    "SatelliteSimPlatformStorage" => "platform/storage",
    "SatelliteSimPlatformScheduler" => "platform/scheduler",
    "SatelliteSimPlatformKubernetes" => "platform/kubernetes",
    "SatelliteSimPlatformControl" => "platform/control",
    "SatelliteSimPlatformBenchmarks" => "platform/benchmarks/constellation-optimization-v1",
)

const ALLOWED_LOCAL_DEPS = Dict(
    "SatelliteSimFoundation" => Set{String}(),
    "SatelliteSimOrbit" => Set(["SatelliteSimFoundation", "SatelliteSimBackends"]),
    "SatelliteSimLink" => Set([
        "SatelliteSimFoundation", "SatelliteSimOrbit", "SatelliteSimBackends",
    ]),
    "SatelliteSimMetrics" => Set(["SatelliteSimFoundation"]),
    "SatelliteSimNet" => Set(["SatelliteSimFoundation", "SatelliteSimLink"]),
    "SatelliteSimTraffic" => Set(["SatelliteSimFoundation", "SatelliteSimLink", "SatelliteSimNet"]),
    "SatelliteSimCore" => Set(["SatelliteSimFoundation", "SatelliteSimOrbit", "SatelliteSimLink", "SatelliteSimMetrics"]),
    "SatelliteSimLab" => Set([
        "SatelliteSimFoundation", "SatelliteSimOrbit", "SatelliteSimLink",
        "SatelliteSimMetrics", "SatelliteSimNet", "SatelliteSimTraffic", "SatelliteSimCore",
        "SatelliteSimBackends",
    ]),
    "SatelliteSimSecurity" => Set([
        "SatelliteSimFoundation", "SatelliteSimLink", "SatelliteSimMetrics",
        "SatelliteSimNet", "SatelliteSimTraffic",
    ]),
    "SatelliteSimOpt" => Set([
        "SatelliteSimFoundation", "SatelliteSimOrbit", "SatelliteSimLink", "SatelliteSimNet",
    ]),
    "GMAT" => Set(["SatelliteSimFoundation"]),
    "SatelliteSimBackends" => Set{String}(),
    "SatelliteSimStubBackend" => Set(["SatelliteSimBackends"]),
    "SatelliteSimJuliaSpaceBackend" => Set(["SatelliteSimBackends", "SatelliteSimOrbit"]),
    "SatelliteSimGPU" => Set(["SatelliteSimBackends"]),
    "PlatformRunner" => Set(["SatelliteSimBackends", "SatelliteSimLab"]),
    "SatelliteSimPlatformStorage" => Set{String}(),
    "SatelliteSimPlatformScheduler" => Set(["SatelliteSimPlatformStorage", "PlatformRunner"]),
    "SatelliteSimPlatformKubernetes" => Set{String}(),
    "SatelliteSimPlatformControl" => Set([
        "PlatformRunner", "SatelliteSimPlatformStorage", "SatelliteSimPlatformKubernetes",
    ]),
    "SatelliteSimPlatformBenchmarks" => Set(["SatelliteSimOpt"]),
)

function dependency_sections(project::AbstractDict, dependency::String)
    return String[
        section for section in DEPENDENCY_SECTIONS
        if haskey(get(project, section, Dict{String,Any}()), dependency)
    ]
end

function repository_projects(root::String)
    projects = String[]
    for (directory, subdirectories, files) in walkdir(root)
        filter!(name -> name ∉ (".git", ".julia", "node_modules"), subdirectories)
        "Project.toml" in files && push!(projects, joinpath(directory, "Project.toml"))
    end
    return sort!(projects)
end

function is_explicit_optional_environment(project_path::String)
    relative_path = replace(relpath(project_path, ROOT), '\\' => '/')
    path_parts = split(relative_path, '/')
    return length(path_parts) >= 3 &&
           path_parts[1] == "envs" &&
           !(path_parts[2] in MAIN_CHAIN_ENVIRONMENTS)
end

failures = String[]
for (package, project_dir) in sort(collect(PACKAGE_PROJECTS); by=first)
    project_path = joinpath(ROOT, project_dir, "Project.toml")
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

for project_path in repository_projects(ROOT)
    project = TOML.parsefile(project_path)
    sections = dependency_sections(project, "CUDA")
    if !isempty(sections) && !is_explicit_optional_environment(project_path)
        relative_path = replace(relpath(project_path, ROOT), '\\' => '/')
        push!(
            failures,
            "$relative_path declares CUDA in [$(join(sections, "], ["))]; CUDA is allowed only in explicit optional environments under envs/",
        )
    end
end

root_project = TOML.parsefile(joinpath(ROOT, "Project.toml"))
root_gpu_sections = dependency_sections(root_project, "SatelliteSimGPU")
isempty(root_gpu_sections) || push!(
    failures,
    "root Project.toml declares SatelliteSimGPU in [$(join(root_gpu_sections, "], ["))]; the optional GPU package must not enter the root environment",
)

for (package, dir) in [
    "SatelliteSimNet" => "src/net",
    "SatelliteSimTraffic" => "src/traffic",
    "SatelliteSimSecurity" => "src/security",
    "SatelliteSimOpt" => "src/opt",
]
    deps = get(TOML.parsefile(joinpath(ROOT, dir, "Project.toml")), "deps", Dict{String,Any}())
    haskey(deps, "SatelliteSimCore") && push!(failures, "$package must not depend on SatelliteSimCore")
end

if isempty(failures)
    println("DEPENDENCY BOUNDARIES: PASS")
else
    println(stderr, "DEPENDENCY BOUNDARIES: FAIL")
    foreach(message -> println(stderr, "  - ", message), failures)
    exit(1)
end

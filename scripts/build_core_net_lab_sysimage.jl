#!/usr/bin/env julia

using PackageCompiler
using Libdl

const REPO_ROOT = dirname(@__DIR__)
const DEFAULT_OUTPUT = joinpath(REPO_ROOT, "build", "SatelliteSimCoreNetLabSysimage." * Libdl.dlext)
const PRECOMPILE_FILE = joinpath(REPO_ROOT, "scripts", "precompile_core_net_lab.jl")

function main(args::Vector{String})::Nothing
    output_path = isempty(args) ? DEFAULT_OUTPUT : abspath(args[1])
    mkpath(dirname(output_path))

    create_sysimage(
        [:SatelliteSimCore, :SatelliteSimNet, :SatelliteSimLab];
        sysimage_path = output_path,
        precompile_execution_file = PRECOMPILE_FILE,
        incremental = true,
    )

    println(output_path)
    return nothing
end

main(ARGS)

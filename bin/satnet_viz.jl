#!/usr/bin/env julia
# satnet_viz.jl — Viz 子进程入口
# 通过 julia --project=envs/viz bin/satnet_viz.jl <subcommand> [args...]
# 由 satnet.jl / SimCLI viz 调用，避免主链预编译 Makie

using JLD2
using SatelliteSimCore
using SatelliteSimViz

function main(args::Vector{String})
    if isempty(args) || args[1] in ("-h", "--help")
        println("""
        SatelliteSimJulia Viz CLI (envs/viz 子进程)

        Usage:
          julia --project=envs/viz bin/satnet_viz.jl snapshot [positions.jld2] [--output path.png]
          julia --project=envs/viz bin/satnet_viz.jl coverage  <jld2_file> [--output path.png]
        """)
        return
    end

    cmd = args[1]
    rest = args[2:end]

    if cmd == "snapshot"
        jld2_file, rest = _positional_arg(rest)
        output = _get_flag(rest, "--output", "snapshot.png")
        positions = _load_or_demo_positions(jld2_file)
        mkpath(dirname(abspath(output)))
        SatelliteSimViz.save_orbit_snapshot(output, positions)
        println("Saved snapshot: $output")
    elseif cmd == "coverage"
        jld2_file, rest = _positional_arg(rest)
        isempty(jld2_file) && error("coverage requires a jld2_file with `positions`")
        output = _get_flag(rest, "--output", "coverage.png")
        positions = _load_positions(jld2_file)
        mkpath(dirname(abspath(output)))
        fig = SatelliteSimViz.plot_coverage_heatmap(positions)
        CairoMakie.save(output, fig)
        println("Saved coverage heatmap: $output")
    else
        error("unknown viz subcommand: $cmd (use snapshot or coverage)")
    end
end

function _positional_arg(args::Vector{String})
    isempty(args) && return ("", String[])
    startswith(args[1], "--") ? ("", args) : (args[1], args[2:end])
end

function _get_flag(args, flag, default)
    idx = findfirst(==(flag), args)
    isnothing(idx) || idx == length(args) ? default : args[idx + 1]
end

function _load_positions(path::AbstractString)
    isfile(path) || error("positions file not found: $path")
    data = jldopen(path, "r")
    haskey(data, "positions") || error("JLD2 file missing `positions` key: $path")
    pos = data["positions"]
    close(data)
    return pos
end

function _load_or_demo_positions(path::AbstractString)
    if isempty(path)
        elems = SatelliteSimCore.generate_walker_delta(; T = 12, P = 3, F = 1)
        tspan = collect(range(0.0, 1800.0; length = 11))
        return SatelliteSimCore.propagate_to_ecef(elems, tspan)
    end
    return _load_positions(path)
end

main(ARGS)

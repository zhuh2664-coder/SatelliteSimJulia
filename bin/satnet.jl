#!/usr/bin/env julia
# satnet.jl — SatelliteSimJulia CLI 入口点
# 使用 using SatelliteSimJulia 加载整个平台，然后调用 CLI。

push!(LOAD_PATH, joinpath(@__DIR__, ".."))
using SatelliteSimJulia

function satnet(args::Vector{String})
    if isempty(args) || args[1] in ("-h", "--help")
        println("""
        SatelliteSimJulia CLI

        Usage:
          julia bin/satnet.jl study list
          julia bin/satnet.jl study run <name> [--export csv]
          julia bin/satnet.jl experiment list
          julia bin/satnet.jl constellation list
          julia bin/satnet.jl sweep run <template>
        """)
        return
    end
    # Dispatch to the CLI module
    if isdefined(SatelliteSimJulia, :satnet)
        SatelliteSimJulia.satnet(args)
    else
        println("CLI not available. Use the Julia REPL:")
        println("  julia --project=. -e 'using SatelliteSimJulia'")
    end
end

if basename(PROGRAM_FILE) == "satnet.jl"
    satnet(ARGS)
end

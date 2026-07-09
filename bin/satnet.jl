#!/usr/bin/env julia
# satnet.jl — SatelliteSimJulia CLI 入口点
# 使用 using SatelliteSimJulia 加载整个平台，然后调用 CLI。

push!(LOAD_PATH, joinpath(@__DIR__, ".."))
using SatelliteSimJulia

function satnet(args::Vector{String})
    SatelliteSimJulia.satnet(args)
end

if basename(PROGRAM_FILE) == "satnet.jl"
    satnet(ARGS)
end

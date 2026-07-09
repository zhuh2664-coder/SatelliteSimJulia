#!/usr/bin/env julia
# satnet-api.jl — PlatformAPI container/local entrypoint

using PlatformAPI

port = parse(Int, get(ENV, "PORT", "8080"))
host = get(ENV, "HOST", "0.0.0.0")

PlatformAPI.start(; host = host, port = port)

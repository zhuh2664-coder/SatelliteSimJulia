#!/usr/bin/env julia

# Probe Revise.jl hot reloading without editing real project source files.

using Test
using Revise

using SatelliteSimOrbit
using SatelliteSimLab

module HotReloadProbe
probe_value() = 0
end

function write_probe_module(path::AbstractString, value::Int)
    write(
        path,
        """
        probe_value() = $value
        """,
    )
    return path
end

function run_revise_probe()
    dir = mktempdir()
    module_path = joinpath(dir, "HotReloadProbe.jl")

    write_probe_module(module_path, 1)
    Revise.includet(HotReloadProbe, module_path)
    @test Base.invokelatest(HotReloadProbe.probe_value) == 1

    # Give file watchers and mtime resolution a clear boundary on macOS.
    sleep(1.1)
    write_probe_module(module_path, 2)
    sleep(1.1)
    Revise.revise()

    @test Base.invokelatest(HotReloadProbe.probe_value) == 2

    println("Revise hot reload probe PASS")
    println("loaded packages: SatelliteSimOrbit, SatelliteSimLab")
    println("temporary module: $module_path")
    return true
end

run_revise_probe()

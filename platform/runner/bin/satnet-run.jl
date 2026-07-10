#!/usr/bin/env julia

using JSON
using PlatformRunner

function usage(io::IO=stdout)
    println(io, "usage: satnet-run.jl --config <experiment.json> --output-dir <directory> [--overwrite]")
end

function main(args)
    config_path = nothing
    output_dir = nothing
    overwrite = false
    index = 1
    while index <= length(args)
        argument = args[index]
        if argument == "--config"
            index += 1
            index <= length(args) || error("--config requires a path")
            config_path = args[index]
        elseif argument == "--output-dir"
            index += 1
            index <= length(args) || error("--output-dir requires a directory")
            output_dir = args[index]
        elseif argument == "--overwrite"
            overwrite = true
        elseif argument in ("-h", "--help")
            usage()
            return 0
        else
            error("unknown argument: $argument")
        end
        index += 1
    end
    config_path === nothing && error("--config is required")
    output_dir === nothing && error("--output-dir is required")
    raw = JSON.parsefile(config_path)
    run = run_platform_experiment(raw; output_dir=output_dir, overwrite=overwrite)
    println(JSON.json(Dict("output_dir" => run["output_dir"], "status" => "succeeded")))
    return 0
end

try
    exit(main(ARGS))
catch error
    Base.showerror(stderr, error, catch_backtrace())
    println(stderr)
    exit(error isa PlatformConfigError ? 1 : 2)
end

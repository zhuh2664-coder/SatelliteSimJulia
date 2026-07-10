#!/usr/bin/env julia

using SatelliteSimPlatformBenchmarks
using JSON

function usage(io::IO=stdout)
    println(io, "Usage: run.jl [--verify] [--output PATH]")
end

function main(args::Vector{String})::Int
    verify = false
    output = nothing
    index = 1
    while index <= length(args)
        argument = args[index]
        if argument == "--verify"
            verify = true
        elseif argument == "--output"
            index == length(args) && (println(stderr, "--output requires a path"); return 2)
            index += 1
            output = args[index]
        elseif argument in ("-h", "--help")
            usage()
            return 0
        else
            println(stderr, "unknown argument: $argument")
            usage(stderr)
            return 2
        end
        index += 1
    end

    result = try
        run_constellation_benchmark()
    catch err
        println(stderr, "benchmark execution failed: ", sprint(showerror, err))
        return 1
    end
    if verify
        try
            verify_benchmark_result(result)
        catch err
            println(stderr, "benchmark verification failed: ", sprint(showerror, err))
            return 1
        end
    end
    if output === nothing
        JSON.print(stdout, result, 2)
        println()
    else
        try
            write_benchmark_result(output, result)
        catch err
            println(stderr, "could not write benchmark result: ", sprint(showerror, err))
            return 2
        end
        println(JSON.json(Dict("output" => abspath(output), "status" => (verify ? "verified" : "completed"))))
    end
    return 0
end

exit(main(ARGS))

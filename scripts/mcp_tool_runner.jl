#!/usr/bin/env julia
# Minimal MCP-ready JSON tool runner for SatelliteSimJulia.
#
# Usage:
#   julia --project=. scripts/mcp_tool_runner.jl list_constellations '{}'
#   julia --project=. scripts/mcp_tool_runner.jl describe_constellation '{"name":"iridium"}'

using JSON
using Printf
using SatelliteSimCore
using SatelliteSimNet
using SatelliteSimLink

const ALLOWED_PACKAGES = Set([
    "SatelliteSimFoundation",
    "SatelliteSimOrbit",
    "SatelliteSimMetrics",
    "SatelliteSimLink",
    "GMAT",
    "SatelliteSimCore",
    "SatelliteSimNet",
    "SatelliteSimTraffic",
    "SatelliteSimLab",
    "SatelliteSimOpt",
    "SatelliteSimViz",
    "SatelliteSimServer",
])

function emit(obj)
    println(JSON.json(obj))
end

function require_key(args::AbstractDict, key::String)
    haskey(args, key) || throw(ArgumentError("missing required argument: $key"))
    return args[key]
end

function get_float(args::AbstractDict, key::String, default::Float64)
    haskey(args, key) || return default
    return Float64(args[key])
end

function get_string(args::AbstractDict, key::String, default::String)
    haskey(args, key) || return default
    return String(args[key])
end

function get_tspan(args::AbstractDict)
    raw = get(args, "tspan", [0.0, 30.0])
    length(raw) == 2 || throw(ArgumentError("tspan must have exactly two values"))
    return Float64.(raw)
end

function walker_config(name::String)
    cfg = resolve_constellation(Symbol(name))
    cfg isa WalkerConstellationConfig || throw(ArgumentError("only WalkerConstellationConfig is supported, got $(typeof(cfg))"))
    return cfg
end

function compute_positions(args::AbstractDict)
    name = String(require_key(args, "name"))
    cfg = walker_config(name)
    tspan = get_tspan(args)
    step_s = get_float(args, "step_s", 10.0)
    step_s > 0 || throw(ArgumentError("step_s must be > 0"))
    ts = collect(tspan[1]:step_s:tspan[2])
    isempty(ts) && throw(ArgumentError("empty time grid from tspan=$tspan step_s=$step_s"))
    prop = Symbol(get_string(args, "propagator", "j2"))
    elems = generate_walker_delta(; T=cfg.T, P=cfg.P, F=cfg.F, alt_km=cfg.alt_km, inc_deg=cfg.inc_deg)
    positions = propagate_to_ecef(elems, ts; propagator=prop)
    return name, cfg, ts, step_s, positions
end

function tool_list_constellations(args::AbstractDict)
    return Dict("names" => String.(string.(list_constellations())))
end

function tool_describe_constellation(args::AbstractDict)
    name = String(require_key(args, "name"))
    cfg = walker_config(name)
    return Dict(
        "name" => name,
        "T" => cfg.T,
        "P" => cfg.P,
        "F" => cfg.F,
        "alt_km" => cfg.alt_km,
        "inc_deg" => cfg.inc_deg,
    )
end

function tool_start_simulation_summary(args::AbstractDict)
    name, cfg, ts, step_s, positions = compute_positions(args)
    return Dict(
        "session_id" => "cli-preview",
        "name" => name,
        "n_sat" => size(positions, 1),
        "n_time" => size(positions, 2),
        "fps" => get_float(args, "fps", 10.0),
        "step_s" => step_s,
        "tspan" => [first(ts), last(ts)],
    )
end

function tool_frame_payload_once(args::AbstractDict)
    name, cfg, ts, step_s, positions = compute_positions(args)
    frame_index = Int(get(args, "frame_index", 1))
    1 <= frame_index <= size(positions, 2) || throw(BoundsError(positions, frame_index))

    topo = generate_topology(GridPlusStrategy(), cfg.T, cfg.P)
    isl_edges = Tuple{Int,Int}[Tuple(e) for e in vcat(topo.static_links, topo.dynamic_candidates)]
    pos_2d = Matrix(positions[:, frame_index, :])
    isl_results = evaluate_isl_batch(pos_2d, isl_edges; constraints=LEO_DEFAULTS)

    return Dict(
        "type" => "frame",
        "session_id" => "cli-preview",
        "name" => name,
        "t" => ts[frame_index],
        "frame_index" => frame_index,
        "n_total" => size(positions, 2),
        "positions" => vec(permutedims(pos_2d)),
        "isl_pairs" => [[i, j] for (i, j) in isl_edges],
        "isl_avail" => [r.available for r in isl_results],
    )
end

function run_capture(cmd::Cmd)
    output_path = tempname()
    ok = false
    combined = ""
    t0 = time()
    try
        open(output_path, "w") do io
            proc = run(pipeline(cmd, stdout=io, stderr=io); wait=true)
            ok = success(proc)
        end
        combined = read(output_path, String)
    catch
        isfile(output_path) && (combined = read(output_path, String))
        ok = false
    finally
        isfile(output_path) && rm(output_path; force=true)
    end
    return ok, time() - t0, combined
end

function marker_for(output::String)
    for line in split(output, '\n')
        occursin("tests passed", line) && return strip(line)
        occursin("Test Summary:", line) && return strip(line)
    end
    return ""
end

function tool_run_pkg_test(args::AbstractDict)
    pkg = String(require_key(args, "package"))
    pkg in ALLOWED_PACKAGES || throw(ArgumentError("package is not allowlisted: $pkg"))
    cmd = pkg == "SatelliteSimServer" ?
        `julia --project=src/server -e "using Pkg; Pkg.test()"` :
        `julia --project=. -e "using Pkg; Pkg.test(\"$pkg\")"`
    ok, duration, output = run_capture(cmd)
    tail_lines = split(output, '\n')[max(1, length(split(output, '\n')) - 10):end]
    return Dict(
        "package" => pkg,
        "success" => ok,
        "duration_s" => duration,
        "marker" => marker_for(output),
        "tail" => [line for line in tail_lines if !isempty(strip(line))],
    )
end

function tool_zcode_token_usage_summary(args::AbstractDict)
    date = get_string(args, "date", "today")
    top = Int(get(args, "top", 10))
    cmd = `python3 scripts/zcode_token_usage_report.py --date $date --top $top`
    ok, duration, output = run_capture(cmd)
    return Dict(
        "success" => ok,
        "duration_s" => duration,
        "text" => output,
    )
end

const TOOLS = Dict{String,Function}(
    "list_constellations" => tool_list_constellations,
    "describe_constellation" => tool_describe_constellation,
    "start_simulation_summary" => tool_start_simulation_summary,
    "frame_payload_once" => tool_frame_payload_once,
    "run_pkg_test" => tool_run_pkg_test,
    "zcode_token_usage_summary" => tool_zcode_token_usage_summary,
)

function main(argv)
    length(argv) >= 1 || throw(ArgumentError("usage: mcp_tool_runner.jl <tool-name> '<json-args>'"))
    tool = argv[1]
    haskey(TOOLS, tool) || throw(ArgumentError("unknown tool: $tool"))
    raw_args = length(argv) >= 2 ? argv[2] : "{}"
    parsed = JSON.parse(raw_args)
    parsed isa AbstractDict || throw(ArgumentError("json args must be an object"))
    result = TOOLS[tool](parsed)
    emit(Dict("ok" => true, "tool" => tool, "result" => result))
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    try
        main(ARGS)
    catch e
        tool = length(ARGS) >= 1 ? ARGS[1] : ""
        emit(Dict(
            "ok" => false,
            "tool" => tool,
            "error_type" => string(typeof(e)),
            "message" => sprint(showerror, e),
        ))
        exit(1)
    end
end

module PlatformRunner

using Dates
using JSON
using SHA
using SatelliteSimBackends
using SatelliteSimLab

export EXPERIMENT_SCHEMA_VERSION, PlatformConfigError,
       validate_experiment_config, experiment_config_from_json,
       run_platform_experiment

const EXPERIMENT_SCHEMA_VERSION = "satellitesim.experiment/v1"
const _ALLOWED_FIELDS = Set([
    "schema_version", "name", "constellation", "propagator", "orbit_backend",
    "tspan", "steps", "topology_strategy", "routing_algorithm", "traffic",
    "ground_pairs", "random_seed", "alpha",
])
const _ALLOWED_PROPAGATORS = Set(["two_body", "j2", "j4"])
const _ALLOWED_TOPOLOGIES = Set(["balanced", "mesh", "gridplus", "grid_plus"])
const _ALLOWED_ROUTING = Set(["dijkstra", "ecmp", "min_load"])
const _ALLOWED_TRAFFIC = Set(["uniform", "hotspot"])

"""A user-facing validation error for the public experiment configuration."""
struct PlatformConfigError <: Exception
    message::String
end
Base.showerror(io::IO, err::PlatformConfigError) = print(io, err.message)

function _asdict(value, field::String)::AbstractDict
    value isa AbstractDict || throw(PlatformConfigError("$field must be an object"))
    return value
end

function _asvector(value, field::String)::AbstractVector
    value isa AbstractVector || throw(PlatformConfigError("$field must be an array"))
    return value
end

function _string_key_dict(value::AbstractDict)
    return Dict{String,Any}(String(key) => item for (key, item) in value)
end

function _finite_number(value, field::String)::Float64
    value isa Real || throw(PlatformConfigError("$field must be a number"))
    number = Float64(value)
    isfinite(number) || throw(PlatformConfigError("$field must be finite"))
    return number
end

function _integer(value, field::String; minimum::Int=typemin(Int))::Int
    value isa Integer || throw(PlatformConfigError("$field must be an integer"))
    result = Int(value)
    result >= minimum || throw(PlatformConfigError("$field must be at least $minimum"))
    return result
end

function _symbol_choice(value, field::String, choices::Set{String})::Symbol
    value isa AbstractString || throw(PlatformConfigError("$field must be a string"))
    selected = String(value)
    selected in choices || throw(PlatformConfigError("$field has unsupported value '$selected'"))
    return Symbol(selected)
end

function _normalise_constellation(value)
    if value isa AbstractString
        isempty(strip(value)) && throw(PlatformConfigError("constellation must not be empty"))
        return String(value)
    end
    input = _string_key_dict(_asdict(value, "constellation"))
    expected = Set(["T", "P", "F", "alt_km", "inc_deg"])
    Set(keys(input)) == expected || throw(PlatformConfigError(
        "constellation object must contain exactly T, P, F, alt_km, inc_deg",
    ))
    T = _integer(input["T"], "constellation.T"; minimum=1)
    P = _integer(input["P"], "constellation.P"; minimum=1)
    F = _integer(input["F"], "constellation.F"; minimum=0)
    P <= T || throw(PlatformConfigError("constellation.P must not exceed constellation.T"))
    F < P || throw(PlatformConfigError("constellation.F must be smaller than constellation.P"))
    alt_km = _finite_number(input["alt_km"], "constellation.alt_km")
    inc_deg = _finite_number(input["inc_deg"], "constellation.inc_deg")
    alt_km > 0 || throw(PlatformConfigError("constellation.alt_km must be positive"))
    0 <= inc_deg <= 180 || throw(PlatformConfigError("constellation.inc_deg must be between 0 and 180"))
    return Dict{String,Any}(
        "T" => T, "P" => P, "F" => F, "alt_km" => alt_km, "inc_deg" => inc_deg,
    )
end

function _normalise_backend(value)
    value === nothing && return nothing
    if value isa AbstractString
        isempty(strip(value)) && throw(PlatformConfigError("orbit_backend must not be empty"))
        return Dict{String,Any}("name" => String(value), "options" => Dict{String,Any}())
    end
    input = _string_key_dict(_asdict(value, "orbit_backend"))
    unknown = setdiff(Set(keys(input)), Set(["name", "options"]))
    isempty(unknown) || throw(PlatformConfigError("orbit_backend has unsupported fields: $(join(sort!(collect(unknown)), ", "))"))
    haskey(input, "name") || throw(PlatformConfigError("orbit_backend.name is required"))
    name = input["name"]
    name isa AbstractString && !isempty(strip(name)) || throw(PlatformConfigError("orbit_backend.name must be a non-empty string"))
    raw_options = get(input, "options", Dict{String,Any}())
    options = _string_key_dict(_asdict(raw_options, "orbit_backend.options"))
    for (key, option) in options
        occursin(r"^[A-Za-z][A-Za-z0-9_]*$", key) || throw(PlatformConfigError("orbit_backend option '$key' is not a valid identifier"))
        option isa Union{AbstractString,Real,Bool} || throw(PlatformConfigError(
            "orbit_backend option '$key' must be a string, number, or boolean",
        ))
        option isa Real && !isfinite(Float64(option)) && throw(PlatformConfigError(
            "orbit_backend option '$key' must be finite",
        ))
    end
    return Dict{String,Any}("name" => String(name), "options" => options)
end

function _normalise_pairs(value)
    pairs = Tuple{Int,Int}[]
    for (index, pair_value) in enumerate(_asvector(value, "ground_pairs"))
        pair = _asvector(pair_value, "ground_pairs[$index]")
        length(pair) == 2 || throw(PlatformConfigError("ground_pairs[$index] must contain exactly two station ids"))
        source = _integer(pair[1], "ground_pairs[$index][1]"; minimum=1)
        target = _integer(pair[2], "ground_pairs[$index][2]"; minimum=1)
        source != target || throw(PlatformConfigError("ground_pairs[$index] must use distinct station ids"))
        push!(pairs, (source, target))
    end
    return pairs
end

"""
    validate_experiment_config(raw) -> Dict{String,Any}

Validate and fill defaults for the public `satellitesim.experiment/v1` JSON
configuration. This validation is deliberately strict: unknown fields and raw
Julia objects are rejected before an experiment reaches a runner.
"""
function validate_experiment_config(raw)::Dict{String,Any}
    input = _string_key_dict(_asdict(raw, "experiment"))
    unknown = setdiff(Set(keys(input)), _ALLOWED_FIELDS)
    isempty(unknown) || throw(PlatformConfigError("unsupported experiment fields: $(join(sort!(collect(unknown)), ", "))"))

    schema_version = get(input, "schema_version", EXPERIMENT_SCHEMA_VERSION)
    schema_version == EXPERIMENT_SCHEMA_VERSION || throw(PlatformConfigError(
        "schema_version must be '$EXPERIMENT_SCHEMA_VERSION'",
    ))
    haskey(input, "name") || throw(PlatformConfigError("name is required"))
    name = input["name"]
    name isa AbstractString && !isempty(strip(name)) || throw(PlatformConfigError("name must be a non-empty string"))
    ncodeunits(name) <= 128 || throw(PlatformConfigError("name must be at most 128 bytes"))
    haskey(input, "constellation") || throw(PlatformConfigError("constellation is required"))

    propagator = _symbol_choice(get(input, "propagator", "j2"), "propagator", _ALLOWED_PROPAGATORS)
    topology = _symbol_choice(get(input, "topology_strategy", "balanced"), "topology_strategy", _ALLOWED_TOPOLOGIES)
    topology in (:mesh, :gridplus, :grid_plus) && (topology = :balanced)
    routing = _symbol_choice(get(input, "routing_algorithm", "dijkstra"), "routing_algorithm", _ALLOWED_ROUTING)
    traffic = _symbol_choice(get(input, "traffic", "uniform"), "traffic", _ALLOWED_TRAFFIC)

    raw_tspan = _asvector(get(input, "tspan", [0.0, 3600.0]), "tspan")
    length(raw_tspan) == 2 || throw(PlatformConfigError("tspan must contain exactly start and stop seconds"))
    start_s = _finite_number(raw_tspan[1], "tspan[1]")
    stop_s = _finite_number(raw_tspan[2], "tspan[2]")
    stop_s > start_s || throw(PlatformConfigError("tspan stop must be greater than start"))
    steps = _integer(get(input, "steps", 30), "steps"; minimum=2)
    steps <= 10_000 || throw(PlatformConfigError("steps must not exceed 10000"))

    random_seed = _integer(get(input, "random_seed", 42), "random_seed"; minimum=0)
    alpha = _finite_number(get(input, "alpha", 0.5), "alpha")
    0 <= alpha <= 1 || throw(PlatformConfigError("alpha must be between 0 and 1"))
    pairs = _normalise_pairs(get(input, "ground_pairs", Any[]))

    return Dict{String,Any}(
        "schema_version" => EXPERIMENT_SCHEMA_VERSION,
        "name" => String(name),
        "constellation" => _normalise_constellation(input["constellation"]),
        "propagator" => String(propagator),
        "orbit_backend" => _normalise_backend(get(input, "orbit_backend", nothing)),
        "tspan" => [start_s, stop_s],
        "steps" => steps,
        "topology_strategy" => String(topology),
        "routing_algorithm" => String(routing),
        "traffic" => String(traffic),
        "ground_pairs" => [[source, target] for (source, target) in pairs],
        "random_seed" => random_seed,
        "alpha" => alpha,
    )
end

function _backend_spec(normalised::Dict{String,Any})
    backend = normalised["orbit_backend"]
    backend === nothing && return nothing
    options = backend["options"]::Dict{String,Any}
    named_options = (; (Symbol(key) => value for (key, value) in options)...)
    return OrbitBackendSpec(backend["name"], named_options)
end

"""Translate a validated public JSON document into the Lab configuration API."""
function experiment_config_from_json(raw)::ExperimentConfig
    normalised = validate_experiment_config(raw)
    constellation = normalised["constellation"]
    start_s, stop_s = normalised["tspan"]
    time_grid = collect(range(start_s, stop_s; length=normalised["steps"]))
    ground_pairs = Tuple{Int,Int}[(pair[1], pair[2]) for pair in normalised["ground_pairs"]]
    common = (;
        name=normalised["name"],
        propagator=Symbol(normalised["propagator"]),
        orbit_backend=_backend_spec(normalised),
        tspan=time_grid,
        topology_strategy=Symbol(normalised["topology_strategy"]),
        routing_algorithm=Symbol(normalised["routing_algorithm"]),
        traffic=Symbol(normalised["traffic"]),
        random_seed=normalised["random_seed"],
        alpha=normalised["alpha"],
        ground_pairs=ground_pairs,
    )

    if constellation isa String
        return ExperimentConfig(; common..., constellation=Symbol(constellation))
    end

    params = Dict{Symbol,Float64}(
        :T => constellation["T"], :P => constellation["P"], :F => constellation["F"],
        :alt_km => constellation["alt_km"], :inc_deg => constellation["inc_deg"],
    )
    return ExperimentConfig(; common..., constellation_params=params)
end

_sha256_file(path::AbstractString) = bytes2hex(sha256(read(path)))

function _write_json(path::AbstractString, value)
    open(path, "w") do io
        JSON.print(io, value, 2)
        write(io, '\n')
    end
    return path
end

function _environment_hash()
    project = Base.active_project()
    project === nothing && return "unknown"
    manifest = joinpath(dirname(project), "Manifest.toml")
    payload = read(project)
    isfile(manifest) && append!(payload, read(manifest))
    return bytes2hex(sha256(payload))
end

function _artifact_index(directory::AbstractString, names::Vector{String})
    return Dict(
        "artifacts" => [Dict(
            "name" => name,
            "bytes" => filesize(joinpath(directory, name)),
            "sha256" => _sha256_file(joinpath(directory, name)),
        ) for name in names],
    )
end

"""
    run_platform_experiment(raw; output_dir, overwrite=false) -> Dict{String,Any}

Execute a schema-validated experiment locally and write the platform-compatible
reproducibility artifact set. Remote object storage and Kubernetes scheduling are
intentionally outside this runner; those services transport these same files.
"""
function run_platform_experiment(raw; output_dir::AbstractString, overwrite::Bool=false)
    normalised = validate_experiment_config(raw)
    if isdir(output_dir) && !isempty(readdir(output_dir)) && !overwrite
        throw(ArgumentError("output_dir '$output_dir' is not empty; use a new directory or overwrite=true"))
    end
    mkpath(output_dir)

    config_path = joinpath(output_dir, "config.snapshot.json")
    result_path = joinpath(output_dir, "result.json")
    metadata_path = joinpath(output_dir, "run_metadata.json")
    index_path = joinpath(output_dir, "artifacts.index.json")
    _write_json(config_path, normalised)

    started_at = now(UTC)
    result = run_experiment(experiment_config_from_json(normalised))
    finished_at = now(UTC)
    result_summary = Dict(String(key) => value for (key, value) in to_dict(result))
    _write_json(result_path, result_summary)

    metadata = Dict{String,Any}(
        "schema_version" => EXPERIMENT_SCHEMA_VERSION,
        "started_at_utc" => string(started_at),
        "finished_at_utc" => string(finished_at),
        "duration_s" => Dates.value(finished_at - started_at) / 1_000,
        "julia_version" => string(VERSION),
        "satellitesim_lab_version" => string(Base.pkgversion(SatelliteSimLab)),
        "environment_sha256" => _environment_hash(),
        "input_config_sha256" => _sha256_file(config_path),
        "orbit_backend" => normalised["orbit_backend"],
        "random_seed" => normalised["random_seed"],
    )
    _write_json(metadata_path, metadata)
    _write_json(index_path, _artifact_index(output_dir, [
        "config.snapshot.json", "result.json", "run_metadata.json",
    ]))

    return Dict(
        "output_dir" => abspath(output_dir),
        "result" => result_summary,
        "metadata" => metadata,
        "artifacts_index" => JSON.parsefile(index_path),
    )
end

end # module

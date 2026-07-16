# ============================================================
# Server streaming adapter
# ============================================================
#
# This adapter deliberately contains no HTTP/WebSocket or JSON concepts.  It
# gives external transports a small, stable surface for preparing a Walker
# simulation and obtaining per-frame data, while keeping propagation, topology
# and link/ground evaluation inside the Lab orchestration package.

export StreamingGroundStation, StreamingSimulation,
       streaming_walker_config, streaming_constellation_names,
       streaming_constellation_metadata, streaming_shell_metadata,
       prepare_streaming_simulation, streaming_frame

"""Transport-neutral ground-station data used by streaming simulations."""
Base.@kwdef struct StreamingGroundStation
    id::String
    name::String
    lat_deg::Float64
    lon_deg::Float64
    alt_km::Float64 = 0.0
end

"""
Prepared domain state for an external frame-streaming adapter.

The type intentionally contains physical simulation data but no server session,
WebSocket, JSON, or client-specific protocol state.
"""
struct StreamingSimulation
    name::String
    constellation::WalkerConstellationConfig
    positions::Array{Float64,3}
    isl_edges::Vector{Tuple{Int,Int}}
    step_s::Float64
    tspan::Vector{Float64}
    constraints
    ground_stations::Vector{StreamingGroundStation}
    include_gsl::Bool
    include_coverage::Bool
end

"""Create a Walker configuration for an external adapter without exposing Core."""
streaming_walker_config(; T::Integer, P::Integer, F::Integer,
                          alt_km::Real, inc_deg::Real) =
    WalkerConstellationConfig(
        T = Int(T), P = Int(P), F = Int(F),
        alt_km = Float64(alt_km), inc_deg = Float64(inc_deg),
    )

"""All catalog constellation names available to an external adapter."""
streaming_constellation_names() = String.(string.(list_constellations()))

function _streaming_walker_config(name::AbstractString)
    config = resolve_constellation(Symbol(name))
    config isa WalkerConstellationConfig ||
        throw(ArgumentError("only Walker constellations are supported for streaming; got $(typeof(config))"))
    return config
end

function _streaming_station(station)
    return StreamingGroundStation(
        id = String(getproperty(station, :id)),
        name = String(getproperty(station, :name)),
        lat_deg = Float64(getproperty(station, :lat_deg)),
        lon_deg = Float64(getproperty(station, :lon_deg)),
        alt_km = Float64(getproperty(station, :alt_km)),
    )
end

function _streaming_times(tspan::AbstractVector{<:Real}, step_s::Real)
    length(tspan) >= 2 || throw(ArgumentError("tspan must contain [start, stop]"))
    t0, t1 = Float64(tspan[1]), Float64(tspan[2])
    t0 < t1 || throw(ArgumentError("tspan[1] must be < tspan[2], got $tspan"))
    step_s > 0 || throw(ArgumentError("step_s must be > 0, got $step_s"))
    return collect(t0:Float64(step_s):t1)
end

"""
    prepare_streaming_simulation(; name, config=nothing, ...) -> StreamingSimulation

Prepare a Walker simulation for an external transport.  `ground_stations` may
contain any values exposing `id`, `name`, `lat_deg`, `lon_deg`, and `alt_km`
properties (for example, a server DTO or a NamedTuple).
"""
function prepare_streaming_simulation(;
    name::AbstractString,
    config::Union{Nothing,WalkerConstellationConfig} = nothing,
    tspan::AbstractVector{<:Real} = [0.0, 600.0],
    step_s::Real = 10.0,
    propagator::AbstractString = "j2",
    ground_stations::AbstractVector = Any[],
    include_gsl::Bool = true,
    include_coverage::Bool = true,
)
    walker = config === nothing ? _streaming_walker_config(name) : config
    times = _streaming_times(tspan, step_s)
    elements = generate_walker_delta(
        T = walker.T, P = walker.P, F = walker.F,
        alt_km = walker.alt_km, inc_deg = walker.inc_deg,
    )
    positions = propagate_to_ecef(elements, times; propagator = Symbol(propagator))
    topology = generate_topology(GridPlusStrategy(), walker.T, walker.P)
    isl_edges = vcat(topology.static_links, topology.dynamic_candidates)
    stations = StreamingGroundStation[_streaming_station(station) for station in ground_stations]

    return StreamingSimulation(
        String(name), walker, positions, isl_edges, Float64(step_s), Float64.(tspan),
        LEO_DEFAULTS, stations, include_gsl, include_coverage,
    )
end

"""Metadata for a catalog or custom prepared streaming simulation."""
function streaming_constellation_metadata(name::AbstractString)
    return streaming_constellation_metadata(String(name), _streaming_walker_config(name))
end

function streaming_constellation_metadata(simulation::StreamingSimulation)
    return streaming_constellation_metadata(simulation.name, simulation.constellation)
end

function streaming_constellation_metadata(name::AbstractString, config::WalkerConstellationConfig)
    return Dict{String,Any}(
        "name" => String(name), "T" => config.T, "P" => config.P, "F" => config.F,
        "alt_km" => config.alt_km, "inc_deg" => config.inc_deg,
    )
end

function streaming_shell_metadata(simulation::StreamingSimulation)
    shell = streaming_constellation_metadata(simulation)
    shell["id"] = 1
    return [shell]
end

function _streaming_ground_station_payload(stations::Vector{StreamingGroundStation})
    return [
        begin
            x, y, z = geodetic_to_ecef_km(station.lat_deg, station.lon_deg, station.alt_km)
            Dict{String,Any}(
                "id" => station.id, "name" => station.name,
                "lat_deg" => station.lat_deg, "lon_deg" => station.lon_deg,
                "alt_km" => station.alt_km, "ecef_km" => [x, y, z],
            )
        end
        for station in stations
    ]
end

"""
    streaming_frame(simulation, frame_index) -> Dict{String,Any}

Return transport-neutral, JSON-compatible data for one 1-based frame.  A
transport adds its own session identifier and message type around this payload.
"""
function streaming_frame(simulation::StreamingSimulation, frame_index::Integer)
    n_time = size(simulation.positions, 2)
    1 ≤ frame_index ≤ n_time ||
        throw(BoundsError(simulation.positions, (:, frame_index, :)))

    pos_frame = position_at_instant(simulation.positions, frame_index)
    isl_results = evaluate_isl_batch(pos_frame, simulation.isl_edges; constraints = simulation.constraints)
    positions = Float64[pos_frame[i, j] for i in 1:size(pos_frame, 1) for j in 1:3]

    payload = Dict{String,Any}(
        "t" => (Int(frame_index) - 1) * simulation.step_s,
        "frame_index" => Int(frame_index),
        "n_total" => Int(n_time),
        "positions" => positions,
        "isl_pairs" => [[Int(a), Int(b)] for (a, b) in simulation.isl_edges],
        "isl_avail" => Bool[result.available for result in isl_results],
    )

    if simulation.include_gsl && !isempty(simulation.ground_stations)
        station_tuples = [(station.lat_deg, station.lon_deg, station.alt_km) for station in simulation.ground_stations]
        avail, _, _, _ = evaluate_gsl_batch(pos_frame, station_tuples; constraints = simulation.constraints)
        n_sat, n_ground = size(avail)
        gsl_avail = Bool[avail[satellite, ground] for satellite in 1:n_sat for ground in 1:n_ground]
        gsl_pairs = [[Int(satellite), Int(ground)] for satellite in 1:n_sat for ground in 1:n_ground if avail[satellite, ground]]
        covered = count(ground -> any(@view avail[:, ground]), 1:n_ground)

        payload["ground_stations"] = _streaming_ground_station_payload(simulation.ground_stations)
        payload["gsl_shape"] = [Int(n_sat), Int(n_ground)]
        payload["gsl_avail"] = gsl_avail
        payload["gsl_pairs"] = gsl_pairs
        if simulation.include_coverage
            payload["coverage_summary"] = Dict{String,Any}(
                "ratio" => n_ground == 0 ? 0.0 : covered / n_ground,
                "covered" => Int(covered), "total" => Int(n_ground),
            )
        end
    end
    return payload
end

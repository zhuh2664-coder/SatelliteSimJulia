# ============================================================
# Simulation sessions: transport lifecycle around Lab streaming state
# ============================================================

using Random
using SatelliteSimLab

"""
A Server-owned session wrapper.

The server owns only lifecycle and frame scheduling.  `simulation` is prepared
and evaluated by SatelliteSimLab's transport-neutral streaming adapter.
"""
mutable struct SimulationSession
    id::String
    simulation::StreamingSimulation
    active::Base.RefValue{Bool}
    frame_index::Base.RefValue{Int}
    fps::Float64
end

# Keep the prior session field surface available to local callers while keeping
# the underlying physical state in the Lab adapter.
const _SIMULATION_FORWARD_FIELDS = (
    :name, :constellation, :positions, :isl_edges, :step_s, :tspan,
    :constraints, :ground_stations, :include_gsl, :include_coverage,
)

function Base.getproperty(session::SimulationSession, name::Symbol)
    name in _SIMULATION_FORWARD_FIELDS &&
        return getproperty(getfield(session, :simulation), name)
    return getfield(session, name)
end

function Base.propertynames(::SimulationSession, private::Bool = false)
    return private ? (fieldnames(SimulationSession)..., _SIMULATION_FORWARD_FIELDS...) :
                     (fieldnames(SimulationSession)..., _SIMULATION_FORWARD_FIELDS...)
end

# 单服务实例、少量并发会话的内存会话表。
const SESSIONS = Dict{String,SimulationSession}()

"""Validate and expand a frame time range for Server compatibility."""
function make_tspan(tspan::AbstractVector{<:Real}, step_s::Real)
    length(tspan) >= 2 || throw(ArgumentError("tspan must contain [start, stop]"))
    t0, t1 = Float64(tspan[1]), Float64(tspan[2])
    t0 < t1 || throw(ArgumentError("tspan[1] must be < tspan[2], got $tspan"))
    step_s > 0 || throw(ArgumentError("step_s must be > 0, got $step_s"))
    return collect(t0:Float64(step_s):t1)
end

"""
    start_session(; name, config=nothing, ...) -> SimulationSession

Prepare a streaming simulation through SatelliteSimLab and retain only the
transport/session lifecycle in SatelliteSimServer.
"""
function start_session(;
    name::AbstractString,
    config = nothing,
    tspan::AbstractVector{<:Real} = [0.0, 600.0],
    step_s::Real = 10.0,
    propagator::AbstractString = "j2",
    fps::Real = 10.0,
    ground_stations::Vector{GroundStationSpec} = GroundStationSpec[],
    include_gsl::Bool = true,
    include_coverage::Bool = true,
)
    station_inputs = [
        (id = station.id, name = station.name, lat_deg = station.lat_deg,
         lon_deg = station.lon_deg, alt_km = station.alt_km)
        for station in ground_stations
    ]
    simulation = prepare_streaming_simulation(
        name = name, config = config, tspan = tspan, step_s = step_s,
        propagator = propagator, ground_stations = station_inputs,
        include_gsl = include_gsl, include_coverage = include_coverage,
    )

    session = SimulationSession(randstring(8), simulation, Ref(true), Ref(1), Float64(fps))
    SESSIONS[session.id] = session
    return session
end

"""Stop a session and remove its transport lifecycle state."""
function stop_session!(session_id::AbstractString)
    session = get(SESSIONS, session_id, nothing)
    session === nothing && return false
    session.active[] = false
    delete!(SESSIONS, session_id)
    return true
end

get_session(session_id::AbstractString) = get(SESSIONS, session_id, nothing)
n_satellites(session::SimulationSession) = size(session.positions, 1)
n_timesteps(session::SimulationSession) = size(session.positions, 2)

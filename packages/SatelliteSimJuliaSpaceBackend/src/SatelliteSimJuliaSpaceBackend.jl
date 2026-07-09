module SatelliteSimJuliaSpaceBackend

using SatelliteSimBackends
import SatelliteSimBackends: backend_capabilities, propagate_orbit
using SatelliteSimOrbit

export JuliaSpaceOrbitBackend

"""Adapter exposing SatelliteSimOrbit through the stable backend contract."""
Base.@kwdef struct JuliaSpaceOrbitBackend <: AbstractOrbitBackend
    propagator::Symbol = :two_body
end

backend_capabilities(::JuliaSpaceOrbitBackend) =
    (frames = (:ecef,), deterministic = true, propagators = (:two_body, :j2, :j4))

function propagate_orbit(backend::JuliaSpaceOrbitBackend, elements, tspan; kwargs...)
    times = Float64.(collect(tspan))
    positions = propagate_to_ecef(elements, times; propagator=backend.propagator, kwargs...)
    result = OrbitResult(Array{Float64,3}(positions), Dict{String,Any}(
        "backend" => backend_name(backend),
        "frame" => "ecef",
        "propagator" => String(backend.propagator),
    ))
    return validate_orbit_result(
        result;
        expected_satellites=length(elements),
        expected_times=length(times),
    )
end

end

module SatelliteSimBackends

export AbstractOrbitBackend, OrbitResult, backend_name, backend_capabilities,
       propagate_orbit, validate_orbit_result

"""Stable boundary implemented by optional orbit propagation backends."""
abstract type AbstractOrbitBackend end

"""Backend-neutral ECEF propagation result. Positions use `(satellite, time, xyz)` in km."""
struct OrbitResult{T<:Real}
    positions_ecef_km::Array{T,3}
    metadata::Dict{String,Any}
end

backend_name(backend::AbstractOrbitBackend)::String = string(nameof(typeof(backend)))
backend_capabilities(::AbstractOrbitBackend) = (frames = (:ecef,), deterministic = false)

function propagate_orbit(backend::AbstractOrbitBackend, elements, tspan; kwargs...)
    throw(MethodError(propagate_orbit, (backend, elements, tspan)))
end

function validate_orbit_result(
    result::OrbitResult;
    expected_satellites::Union{Nothing,Integer}=nothing,
    expected_times::Union{Nothing,Integer}=nothing,
)::OrbitResult
    size(result.positions_ecef_km, 3) == 3 ||
        throw(ArgumentError("orbit backend result must have xyz size 3"))
    expected_satellites === nothing || size(result.positions_ecef_km, 1) == expected_satellites ||
        throw(ArgumentError("orbit backend satellite count mismatch"))
    expected_times === nothing || size(result.positions_ecef_km, 2) == expected_times ||
        throw(ArgumentError("orbit backend time count mismatch"))
    all(isfinite, result.positions_ecef_km) ||
        throw(ArgumentError("orbit backend result contains non-finite positions"))
    return result
end

end

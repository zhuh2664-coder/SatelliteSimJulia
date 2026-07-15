# ===== Optional orbit-backend dispatch =====
#
# SatelliteSimOrbit owns the native propagators.  This adapter point lets callers
# explicitly choose an implementation that satisfies SatelliteSimBackends without
# coupling the main Orbit API to any heavy backend package.

import SatelliteSimBackends: AbstractOrbitBackend, OrbitResult, propagate_orbit,
                             validate_orbit_result

export propagate_with_backend

"""
    propagate_with_backend(backend, elements, tspan; kwargs...) -> OrbitResult

Propagate `elements` through an explicitly supplied `AbstractOrbitBackend` and
validate the stable backend result contract.  The result positions are ECEF, in
km, and shaped `(satellite, time, xyz)`.

This is deliberately an explicit low-level selection point: applications import
and construct optional backend types themselves, while the standard
`propagate_to_ecef(elements, tspan; propagator=...)` path remains unchanged.
"""
function propagate_with_backend(
    backend::AbstractOrbitBackend,
    elements,
    tspan;
    kwargs...,
)::OrbitResult
    times = Float64.(collect(tspan))
    expected_satellites = try
        length(elements)
    catch error
        error isa MethodError || rethrow()
        nothing
    end
    result = propagate_orbit(backend, elements, times; kwargs...)
    result isa OrbitResult || throw(ArgumentError(
        "orbit backend $(typeof(backend)) must return SatelliteSimBackends.OrbitResult",
    ))
    return validate_orbit_result(
        result;
        expected_satellites=expected_satellites,
        expected_times=length(times),
    )
end

"""
    propagate_to_ecef(backend, elements, tspan; kwargs...) -> Array{<:Real,3}

Convenience form of [`propagate_with_backend`](@ref) that returns the bare ECEF
position array expected by Link, Net, Traffic, and Lab.  It preserves the
existing array data contract while making backend dispatch an opt-in choice.
"""
function propagate_to_ecef(
    backend::AbstractOrbitBackend,
    elements,
    tspan;
    kwargs...,
)
    return propagate_with_backend(backend, elements, tspan; kwargs...).positions_ecef_km
end

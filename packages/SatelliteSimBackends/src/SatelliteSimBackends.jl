module SatelliteSimBackends

export AbstractOrbitBackend, OrbitResult, OrbitBackendSpec,
       backend_name, backend_capabilities, propagate_orbit, validate_orbit_result,
       register_orbit_backend!, unregister_orbit_backend!, orbit_backend_registered,
       available_orbit_backends, create_orbit_backend

"""Stable boundary implemented by optional orbit propagation backends."""
abstract type AbstractOrbitBackend end

"""Backend-neutral ECEF propagation result. Positions use `(satellite, time, xyz)` in km."""
struct OrbitResult{T<:Real}
    positions_ecef_km::Array{T,3}
    metadata::Dict{String,Any}
end

"""
    OrbitBackendSpec(name; kwargs...)

Serializable, backend-neutral selection and configuration for an orbit backend.
The concrete backend package remains an explicit dependency: load it first so it
can register `name`, then pass the spec to `create_orbit_backend` or a higher-level
experiment configuration.
"""
struct OrbitBackendSpec
    name::Symbol
    options::NamedTuple

    function OrbitBackendSpec(name::Symbol, options::NamedTuple=NamedTuple())
        isempty(String(name)) && throw(ArgumentError("orbit backend name must not be empty"))
        return new(name, options)
    end
end

OrbitBackendSpec(name::Union{Symbol,AbstractString}; kwargs...) =
    OrbitBackendSpec(Symbol(name), (; kwargs...))

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

# Optional packages register lightweight factories during `__init__`. The
# registry lives in the contract package so callers can discover and configure
# backends without importing concrete implementation types into Lab/Core APIs.
const _ORBIT_BACKEND_REGISTRY_LOCK = ReentrantLock()
const _ORBIT_BACKEND_FACTORIES = Dict{Symbol,Function}()

"""
    register_orbit_backend!(name, factory; replace=false)

Register a factory with signature `factory(options::NamedTuple) -> AbstractOrbitBackend`.
Optional backend packages should call this from `__init__`; `replace=true` makes
re-initialization idempotent during development.
"""
function register_orbit_backend!(
    name::Union{Symbol,AbstractString},
    factory::Function;
    replace::Bool=false,
)::Symbol
    key = Symbol(name)
    isempty(String(key)) && throw(ArgumentError("orbit backend name must not be empty"))
    lock(_ORBIT_BACKEND_REGISTRY_LOCK) do
        if haskey(_ORBIT_BACKEND_FACTORIES, key) && !replace
            throw(ArgumentError("orbit backend :$key is already registered"))
        end
        _ORBIT_BACKEND_FACTORIES[key] = factory
    end
    return key
end

"""Remove a registered backend. Primarily useful for tests and package reloads."""
function unregister_orbit_backend!(name::Union{Symbol,AbstractString})::Bool
    key = Symbol(name)
    return lock(_ORBIT_BACKEND_REGISTRY_LOCK) do
        pop!(_ORBIT_BACKEND_FACTORIES, key, nothing) !== nothing
    end
end

"""Return whether a backend name is currently registered in this Julia session."""
function orbit_backend_registered(name::Union{Symbol,AbstractString})::Bool
    key = Symbol(name)
    return lock(_ORBIT_BACKEND_REGISTRY_LOCK) do
        haskey(_ORBIT_BACKEND_FACTORIES, key)
    end
end

"""Return registered backend names in deterministic sorted order."""
function available_orbit_backends()::Vector{Symbol}
    return lock(_ORBIT_BACKEND_REGISTRY_LOCK) do
        sort!(collect(keys(_ORBIT_BACKEND_FACTORIES)); by=String)
    end
end

"""
    create_orbit_backend(spec) -> AbstractOrbitBackend
    create_orbit_backend(name; kwargs...) -> AbstractOrbitBackend

Construct a registered backend without exposing its concrete type to callers.
Registration is explicit and session-local: users must first load the optional
package that owns the selected backend.
"""
function create_orbit_backend(spec::OrbitBackendSpec)::AbstractOrbitBackend
    factory = lock(_ORBIT_BACKEND_REGISTRY_LOCK) do
        get(_ORBIT_BACKEND_FACTORIES, spec.name, nothing)
    end
    if factory === nothing
        available = available_orbit_backends()
        suffix = isempty(available) ? "none are registered" :
                 "available: $(join(":" .* String.(available), ", "))"
        throw(ArgumentError(
            "orbit backend :$(spec.name) is not registered ($suffix); " *
            "load the optional backend package before running the experiment",
        ))
    end
    backend = factory(spec.options)
    backend isa AbstractOrbitBackend || throw(ArgumentError(
        "factory for orbit backend :$(spec.name) returned $(typeof(backend)); " *
        "expected AbstractOrbitBackend",
    ))
    return backend
end

create_orbit_backend(name::Union{Symbol,AbstractString}; kwargs...) =
    create_orbit_backend(OrbitBackendSpec(name; kwargs...))

end

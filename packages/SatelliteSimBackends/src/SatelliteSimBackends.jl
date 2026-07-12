module SatelliteSimBackends

export AbstractOrbitBackend, OrbitResult, OrbitBackendSpec,
       backend_name, backend_capabilities, propagate_orbit, validate_orbit_result,
       register_orbit_backend!, unregister_orbit_backend!, orbit_backend_registered,
       available_orbit_backends, create_orbit_backend,
       AbstractComputeBackend, CPUComputeBackend, ComputeBackendSpec,
       GSLSeriesResult, ISLSeriesResult, compute_backend_name, compute_backend_capabilities,
       compute_backend_cache_token, compute_backend_fingerprint,
       compute_backend_source_files,
       evaluate_gsl_series, validate_gsl_series_result,
       evaluate_isl_series, validate_isl_series_result,
       register_compute_backend!, unregister_compute_backend!,
       compute_backend_registered, available_compute_backends, create_compute_backend

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
OrbitBackendSpec(name::AbstractString, options::NamedTuple) =
    OrbitBackendSpec(Symbol(name), options)

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

"""Stable boundary implemented by optional accelerated compute backends."""
abstract type AbstractComputeBackend end

"""Built-in host selection; `SatelliteSimLink` provides its GSL implementation."""
struct CPUComputeBackend <: AbstractComputeBackend end

"""
    ComputeBackendSpec(name; kwargs...)

Serializable selection for an operation-level compute backend. This is
deliberately separate from `OrbitBackendSpec`: an orbit backend selects a
propagation implementation, while a compute backend selects where supported
batched kernels execute.
"""
struct ComputeBackendSpec
    name::Symbol
    options::NamedTuple

    function ComputeBackendSpec(name::Symbol, options::NamedTuple=NamedTuple())
        isempty(String(name)) && throw(ArgumentError("compute backend name must not be empty"))
        return new(name, options)
    end
end

ComputeBackendSpec(name::Union{Symbol,AbstractString}; kwargs...) =
    ComputeBackendSpec(Symbol(name), (; kwargs...))
ComputeBackendSpec(name::AbstractString, options::NamedTuple) =
    ComputeBackendSpec(Symbol(name), options)

compute_backend_name(backend::AbstractComputeBackend)::String =
    string(nameof(typeof(backend)))
compute_backend_name(::CPUComputeBackend) = "cpu"

compute_backend_capabilities(::AbstractComputeBackend) = (
    operations=(),
    device=:unknown,
    input_residency=:host,
    output_residency=:host,
)
compute_backend_capabilities(::CPUComputeBackend) = (
    operations=(:gsl_series, :isl_series),
    device=:cpu,
    input_residency=:host,
    output_residency=:host,
)

function _package_version(module_)::String
    return try
        version = Base.pkgversion(module_)
        version === nothing ? "unknown" : string(version)
    catch
        "unknown"
    end
end

"""
Return deterministic, result-affecting instance state for cache provenance.
Backends that do not implement this are deliberately treated as uncacheable.
"""
compute_backend_cache_token(::AbstractComputeBackend) = nothing

"""
Describe the concrete implementation behind a resolved compute backend.
Optional packages should extend this when the implementation lives outside
the module that owns the backend type.
"""
function compute_backend_fingerprint(backend::AbstractComputeBackend)
    module_ = parentmodule(typeof(backend))
    return (
        name=compute_backend_name(backend),
        type=string(typeof(backend)),
        implementation_module=string(module_),
        implementation_version=_package_version(module_),
        capabilities=compute_backend_capabilities(backend),
        cache_token=compute_backend_cache_token(backend),
    )
end

"""Source files whose contents affect the resolved backend implementation."""
compute_backend_source_files(::AbstractComputeBackend) = String[]

"""
Host-resident GSL results for all `(satellite, station, time)` combinations.
Optional accelerators own device transfers internally so layer boundaries keep
using ordinary Julia arrays.
"""
struct GSLSeriesResult
    available::Array{Bool,3}
    distance_km::Array{Float64,3}
    elevation_deg::Array{Float64,3}
    delay_ms::Array{Float64,3}
    metadata::Dict{String,Any}
end

function evaluate_gsl_series(
    backend::AbstractComputeBackend,
    positions,
    stations;
    gsl_min_elevation_deg,
    gsl_max_range_km,
)
    throw(MethodError(evaluate_gsl_series, (backend, positions, stations)))
end

function validate_gsl_series_result(
    result::GSLSeriesResult;
    expected_satellites::Union{Nothing,Integer}=nothing,
    expected_stations::Union{Nothing,Integer}=nothing,
    expected_times::Union{Nothing,Integer}=nothing,
)::GSLSeriesResult
    output_size = size(result.available)
    size(result.distance_km) == output_size ||
        throw(ArgumentError("GSL distance shape must match availability shape"))
    size(result.elevation_deg) == output_size ||
        throw(ArgumentError("GSL elevation shape must match availability shape"))
    size(result.delay_ms) == output_size ||
        throw(ArgumentError("GSL delay shape must match availability shape"))
    expected_satellites === nothing || output_size[1] == expected_satellites ||
        throw(ArgumentError("GSL satellite count mismatch"))
    expected_stations === nothing || output_size[2] == expected_stations ||
        throw(ArgumentError("GSL station count mismatch"))
    expected_times === nothing || output_size[3] == expected_times ||
        throw(ArgumentError("GSL time count mismatch"))
    all(isfinite, result.distance_km) ||
        throw(ArgumentError("GSL distances contain non-finite values"))
    all(isfinite, result.elevation_deg) ||
        throw(ArgumentError("GSL elevations contain non-finite values"))
    all(isfinite, result.delay_ms) ||
        throw(ArgumentError("GSL delays contain non-finite values"))
    all(value -> value >= 0, result.distance_km) ||
        throw(ArgumentError("GSL distances must be non-negative"))
    all(value -> value >= 0, result.delay_ms) ||
        throw(ArgumentError("GSL delays must be non-negative"))
    return result
end

"""
Host-resident ISL results for all `(pair, time)` combinations. Every field is a
`(n_pairs, n_times)` array: the first axis follows the input `isl_pairs` order,
the second axis follows the position time samples. Optional accelerators own
device transfers internally so layer boundaries keep using ordinary Julia
arrays, mirroring `GSLSeriesResult`.

字段：`available`（是否满足全部约束）、`distance_km`、`delay_ms`、
`line_of_sight`（地球遮挡判定）、`elevation_deg`（RTN 相对仰角）、
`cos_psi`（RTN 方位角余弦）、`duration_s`（直线外推可持续时长）。
"""
struct ISLSeriesResult
    available::Array{Bool,2}
    distance_km::Array{Float64,2}
    delay_ms::Array{Float64,2}
    line_of_sight::Array{Bool,2}
    elevation_deg::Array{Float64,2}
    cos_psi::Array{Float64,2}
    duration_s::Array{Float64,2}
    metadata::Dict{String,Any}
end

function evaluate_isl_series(
    backend::AbstractComputeBackend,
    positions,
    isl_pairs;
    kwargs...,
)
    throw(MethodError(evaluate_isl_series, (backend, positions, isl_pairs)))
end

function validate_isl_series_result(
    result::ISLSeriesResult;
    expected_pairs::Union{Nothing,Integer}=nothing,
    expected_times::Union{Nothing,Integer}=nothing,
)::ISLSeriesResult
    output_size = size(result.available)
    size(result.distance_km) == output_size ||
        throw(ArgumentError("ISL distance shape must match availability shape"))
    size(result.delay_ms) == output_size ||
        throw(ArgumentError("ISL delay shape must match availability shape"))
    size(result.line_of_sight) == output_size ||
        throw(ArgumentError("ISL line-of-sight shape must match availability shape"))
    size(result.elevation_deg) == output_size ||
        throw(ArgumentError("ISL elevation shape must match availability shape"))
    size(result.cos_psi) == output_size ||
        throw(ArgumentError("ISL cos_psi shape must match availability shape"))
    size(result.duration_s) == output_size ||
        throw(ArgumentError("ISL duration shape must match availability shape"))
    expected_pairs === nothing || output_size[1] == expected_pairs ||
        throw(ArgumentError("ISL pair count mismatch"))
    expected_times === nothing || output_size[2] == expected_times ||
        throw(ArgumentError("ISL time count mismatch"))
    all(isfinite, result.distance_km) ||
        throw(ArgumentError("ISL distances contain non-finite values"))
    all(isfinite, result.delay_ms) ||
        throw(ArgumentError("ISL delays contain non-finite values"))
    all(isfinite, result.elevation_deg) ||
        throw(ArgumentError("ISL elevations contain non-finite values"))
    all(isfinite, result.cos_psi) ||
        throw(ArgumentError("ISL cos_psi contain non-finite values"))
    all(isfinite, result.duration_s) ||
        throw(ArgumentError("ISL durations contain non-finite values"))
    all(value -> value >= 0, result.distance_km) ||
        throw(ArgumentError("ISL distances must be non-negative"))
    all(value -> value >= 0, result.delay_ms) ||
        throw(ArgumentError("ISL delays must be non-negative"))
    all(value -> value >= 0, result.duration_s) ||
        throw(ArgumentError("ISL durations must be non-negative"))
    return result
end

const _COMPUTE_BACKEND_REGISTRY_LOCK = ReentrantLock()
const _COMPUTE_BACKEND_FACTORIES = Dict{Symbol,Function}()

"""
    register_compute_backend!(name, factory; replace=false)

Register an optional compute backend factory with signature
`factory(options::NamedTuple) -> AbstractComputeBackend`. The built-in `:cpu`
backend is always available and cannot be replaced.
"""
function register_compute_backend!(
    name::Union{Symbol,AbstractString},
    factory::Function;
    replace::Bool=false,
)::Symbol
    key = Symbol(name)
    isempty(String(key)) && throw(ArgumentError("compute backend name must not be empty"))
    key == :cpu && throw(ArgumentError("the built-in :cpu compute backend cannot be replaced"))
    lock(_COMPUTE_BACKEND_REGISTRY_LOCK) do
        if haskey(_COMPUTE_BACKEND_FACTORIES, key) && !replace
            throw(ArgumentError("compute backend :$key is already registered"))
        end
        _COMPUTE_BACKEND_FACTORIES[key] = factory
    end
    return key
end

function unregister_compute_backend!(name::Union{Symbol,AbstractString})::Bool
    key = Symbol(name)
    key == :cpu && return false
    return lock(_COMPUTE_BACKEND_REGISTRY_LOCK) do
        pop!(_COMPUTE_BACKEND_FACTORIES, key, nothing) !== nothing
    end
end

function compute_backend_registered(name::Union{Symbol,AbstractString})::Bool
    key = Symbol(name)
    key == :cpu && return true
    return lock(_COMPUTE_BACKEND_REGISTRY_LOCK) do
        haskey(_COMPUTE_BACKEND_FACTORIES, key)
    end
end

function available_compute_backends()::Vector{Symbol}
    registered = lock(_COMPUTE_BACKEND_REGISTRY_LOCK) do
        collect(keys(_COMPUTE_BACKEND_FACTORIES))
    end
    return sort!(push!(registered, :cpu); by=String)
end

function create_compute_backend(spec::ComputeBackendSpec)::AbstractComputeBackend
    if spec.name == :cpu
        isempty(spec.options) ||
            throw(ArgumentError("the built-in :cpu compute backend accepts no options"))
        return CPUComputeBackend()
    end

    factory = lock(_COMPUTE_BACKEND_REGISTRY_LOCK) do
        get(_COMPUTE_BACKEND_FACTORIES, spec.name, nothing)
    end
    if factory === nothing
        available = available_compute_backends()
        throw(ArgumentError(
            "compute backend :$(spec.name) is not registered " *
            "(available: $(join(":" .* String.(available), ", "))); " *
            "load its optional package and register the device backend first",
        ))
    end
    backend = factory(spec.options)
    backend isa AbstractComputeBackend || throw(ArgumentError(
        "factory for compute backend :$(spec.name) returned $(typeof(backend)); " *
        "expected AbstractComputeBackend",
    ))
    return backend
end

create_compute_backend(name::Union{Symbol,AbstractString}; kwargs...) =
    create_compute_backend(ComputeBackendSpec(name; kwargs...))

end

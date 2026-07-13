module SatelliteSimBackends

export AbstractOrbitBackend, OrbitResult, OrbitBackendSpec,
       backend_name, backend_capabilities, propagate_orbit, validate_orbit_result,
       register_orbit_backend!, unregister_orbit_backend!, orbit_backend_registered,
       available_orbit_backends, create_orbit_backend,
       AbstractComputeBackend, CPUComputeBackend, ComputeBackendSpec,
       ResolvedComputeBackend, resolve_compute_backend,
       compute_backend_spec, compute_backend_provenance,
       GSLSeriesResult, ISLSeriesResult, compute_backend_name, compute_backend_capabilities,
       compute_backend_cache_token, compute_backend_fingerprint,
       compute_backend_source_files,
       evaluate_gsl_series, validate_gsl_series_result,
       evaluate_isl_series, validate_isl_series_result,
       register_compute_backend!, unregister_compute_backend!,
       compute_backend_registered, available_compute_backends, create_compute_backend,
       BackendOptionSpec, BackendOptionsSchema,
       validate_backend_options, migrate_backend_options

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

mutable struct _ResolvedComputeBackendToken end
const _RESOLVED_COMPUTE_BACKEND_TOKEN = _ResolvedComputeBackendToken()

mutable struct _ComputeBackendExecutionState
    lock::ReentrantLock
    gsl_call_count::UInt64
end

"""
Opaque binding between a requested compute-backend spec and the concrete
implementation selected from the registry. Instances are created only by
`resolve_compute_backend`; callers pass the binding itself to compute
operations so a spec cannot be paired with a different implementation.
"""
struct ResolvedComputeBackend <: AbstractComputeBackend
    _spec::ComputeBackendSpec
    _backend::AbstractComputeBackend
    _implementation::NamedTuple
    _capabilities::NamedTuple
    _registration_generation::UInt64
    _resolution_id::UInt64
    _execution_state::_ComputeBackendExecutionState

    function ResolvedComputeBackend(
        token::_ResolvedComputeBackendToken,
        spec::ComputeBackendSpec,
        backend::AbstractComputeBackend,
        implementation::NamedTuple,
        capabilities::NamedTuple,
        registration_generation::UInt64,
        resolution_id::UInt64,
    )
        token === _RESOLVED_COMPUTE_BACKEND_TOKEN ||
            throw(ArgumentError("compute backend resolutions must be created by resolve_compute_backend"))
        return new(
            spec,
            backend,
            implementation,
            capabilities,
            registration_generation,
            resolution_id,
            _ComputeBackendExecutionState(ReentrantLock(), 0),
        )
    end
end

compute_backend_name(backend::AbstractComputeBackend)::String =
    string(nameof(typeof(backend)))
compute_backend_name(::CPUComputeBackend) = "cpu"

compute_backend_capabilities(::AbstractComputeBackend) = (
    operations=(),
    device=:unknown,
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

compute_backend_spec(resolution::ResolvedComputeBackend) = resolution._spec
compute_backend_name(resolution::ResolvedComputeBackend) =
    resolution._implementation.name
compute_backend_capabilities(resolution::ResolvedComputeBackend) =
    resolution._capabilities
compute_backend_cache_token(resolution::ResolvedComputeBackend) =
    compute_backend_cache_token(resolution._backend)
compute_backend_fingerprint(resolution::ResolvedComputeBackend) =
    compute_backend_fingerprint(resolution._backend)
compute_backend_source_files(resolution::ResolvedComputeBackend) =
    compute_backend_source_files(resolution._backend)

function _gsl_call_count(resolution::ResolvedComputeBackend)::UInt64
    state = resolution._execution_state
    return lock(state.lock) do
        state.gsl_call_count
    end
end

"""
Return the immutable identity snapshot captured at resolution time together
with the number of GSL calls that have returned from the bound implementation.
"""
function compute_backend_provenance(resolution::ResolvedComputeBackend)
    return (
        requested_spec=(
            name=resolution._spec.name,
            options=resolution._spec.options,
        ),
        implementation=resolution._implementation,
        capabilities=resolution._capabilities,
        registration_generation=resolution._registration_generation,
        resolution_id=resolution._resolution_id,
        call_count=_gsl_call_count(resolution),
    )
end

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

function evaluate_gsl_series(
    resolution::ResolvedComputeBackend,
    positions,
    stations;
    gsl_min_elevation_deg,
    gsl_max_range_km,
)
    result = evaluate_gsl_series(
        resolution._backend,
        positions,
        stations;
        gsl_min_elevation_deg=gsl_min_elevation_deg,
        gsl_max_range_km=gsl_max_range_km,
    )
    state = resolution._execution_state
    lock(state.lock) do
        state.gsl_call_count += 1
    end
    result isa GSLSeriesResult || throw(ArgumentError(
        "compute backend '$(resolution._implementation.name)' returned $(typeof(result)); " *
        "expected GSLSeriesResult",
    ))
    reported_backend = get(result.metadata, "backend", nothing)
    reported_backend == resolution._implementation.name || throw(ArgumentError(
        "GSL result backend identity mismatch: resolved " *
        "'$(resolution._implementation.name)' but result metadata reported " *
        "$(repr(reported_backend))",
    ))
    return result
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
    all(value -> 0 <= value <= 90, result.elevation_deg) ||
        throw(ArgumentError("ISL elevations must be in [0, 90] degrees"))
    all(value -> -1 <= value <= 1, result.cos_psi) ||
        throw(ArgumentError("ISL cos_psi values must be in [-1, 1]"))
    return result
end

const _COMPUTE_BACKEND_REGISTRY_LOCK = ReentrantLock()
const _COMPUTE_BACKEND_FACTORIES = Dict{Symbol,Function}()
const _COMPUTE_BACKEND_GENERATIONS = Dict{Symbol,UInt64}()
const _NEXT_COMPUTE_BACKEND_RESOLUTION_ID = Ref{UInt64}(0)

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
        generation = get(_COMPUTE_BACKEND_GENERATIONS, key, UInt64(0)) + UInt64(1)
        _COMPUTE_BACKEND_FACTORIES[key] = factory
        _COMPUTE_BACKEND_GENERATIONS[key] = generation
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

function _compute_backend_factory_snapshot(spec::ComputeBackendSpec)
    if spec.name == :cpu
        isempty(spec.options) ||
            throw(ArgumentError("the built-in :cpu compute backend accepts no options"))
        return nothing, UInt64(1)
    end

    factory, generation = lock(_COMPUTE_BACKEND_REGISTRY_LOCK) do
        (
            get(_COMPUTE_BACKEND_FACTORIES, spec.name, nothing),
            get(_COMPUTE_BACKEND_GENERATIONS, spec.name, UInt64(0)),
        )
    end
    if factory === nothing
        available = available_compute_backends()
        throw(ArgumentError(
            "compute backend :$(spec.name) is not registered " *
            "(available: $(join(":" .* String.(available), ", "))); " *
            "load its optional package and register the device backend first",
        ))
    end
    return factory, generation
end

function _instantiate_compute_backend(spec::ComputeBackendSpec)
    factory, generation = _compute_backend_factory_snapshot(spec)
    backend = factory === nothing ? CPUComputeBackend() : factory(spec.options)
    backend isa AbstractComputeBackend || throw(ArgumentError(
        "factory for compute backend :$(spec.name) returned $(typeof(backend)); " *
        "expected AbstractComputeBackend",
    ))
    backend isa ResolvedComputeBackend && throw(ArgumentError(
        "factory for compute backend :$(spec.name) returned a resolution wrapper; " *
        "expected a concrete AbstractComputeBackend implementation",
    ))
    capabilities = compute_backend_capabilities(backend)
    capabilities isa NamedTuple || throw(ArgumentError(
        "compute backend :$(spec.name) capabilities must be a NamedTuple",
    ))
    if spec.name != :cpu
        device = hasproperty(capabilities, :device) ?
            Symbol(lowercase(string(capabilities.device))) : :unknown
        if backend isa CPUComputeBackend || device == :cpu
            throw(ArgumentError(
                "requested non-CPU compute backend :$(spec.name) resolved to " *
                "CPU device/CPUComputeBackend",
            ))
        end
    end
    return backend, capabilities, generation
end

function _immutable_backend_snapshot(value::NamedTuple)
    return (; (
        name => _immutable_backend_snapshot(getproperty(value, name))
        for name in propertynames(value)
    )...)
end
_immutable_backend_snapshot(value::Tuple) =
    map(_immutable_backend_snapshot, value)
_immutable_backend_snapshot(value::AbstractArray) =
    Tuple(_immutable_backend_snapshot(item) for item in value)
_immutable_backend_snapshot(value::Pair) =
    _immutable_backend_snapshot(first(value)) =>
    _immutable_backend_snapshot(last(value))
function _immutable_backend_snapshot(value::AbstractDict)
    entries = sort!(collect(value); by=entry -> repr(first(entry)))
    return Tuple(_immutable_backend_snapshot(entry) for entry in entries)
end
function _immutable_backend_snapshot(value::AbstractSet)
    entries = sort!(collect(value); by=repr)
    return Tuple(_immutable_backend_snapshot(entry) for entry in entries)
end
_immutable_backend_snapshot(value::AbstractString) = String(value)
_immutable_backend_snapshot(value::Symbol) = value
_immutable_backend_snapshot(value::Number) = value
_immutable_backend_snapshot(value::Char) = value
_immutable_backend_snapshot(::Nothing) = nothing
_immutable_backend_snapshot(::Missing) = missing
_immutable_backend_snapshot(value::Type) = value
_immutable_backend_snapshot(value) = isbits(value) ? value : (
    type=string(typeof(value)),
    representation=repr(value),
)

function _compute_backend_implementation_snapshot(backend::AbstractComputeBackend)
    fingerprint = compute_backend_fingerprint(backend)
    module_ = parentmodule(typeof(backend))
    return (
        name=String(compute_backend_name(backend)),
        type=string(
            hasproperty(fingerprint, :type) ? fingerprint.type : typeof(backend),
        ),
        implementation_module=string(
            hasproperty(fingerprint, :implementation_module) ?
            fingerprint.implementation_module : module_,
        ),
        implementation_version=string(
            hasproperty(fingerprint, :implementation_version) ?
            fingerprint.implementation_version : _package_version(module_),
        ),
    )
end

function _next_compute_backend_resolution_id()::UInt64
    return lock(_COMPUTE_BACKEND_REGISTRY_LOCK) do
        _NEXT_COMPUTE_BACKEND_RESOLUTION_ID[] += UInt64(1)
    end
end

function create_compute_backend(spec::ComputeBackendSpec)::AbstractComputeBackend
    backend, _, _ = _instantiate_compute_backend(spec)
    return backend
end

create_compute_backend(name::Union{Symbol,AbstractString}; kwargs...) =
    create_compute_backend(ComputeBackendSpec(name; kwargs...))

"""
    resolve_compute_backend(spec) -> ResolvedComputeBackend
    resolve_compute_backend(name; kwargs...) -> ResolvedComputeBackend

Resolve a compute backend exactly once and bind the requested spec to the
concrete instance, identity/capability snapshot, registry generation, and a
per-resolution identifier.
"""
function resolve_compute_backend(spec::ComputeBackendSpec)::ResolvedComputeBackend
    backend, capabilities, generation = _instantiate_compute_backend(spec)
    return ResolvedComputeBackend(
        _RESOLVED_COMPUTE_BACKEND_TOKEN,
        spec,
        backend,
        _compute_backend_implementation_snapshot(backend),
        _immutable_backend_snapshot(capabilities),
        generation,
        _next_compute_backend_resolution_id(),
    )
end

resolve_compute_backend(name::Union{Symbol,AbstractString}; kwargs...) =
    resolve_compute_backend(ComputeBackendSpec(name; kwargs...))

# ── Backend options schema (draft) ──────────────────────────────────────────

"""
    BackendOptionSpec(name, type; required=false, default=nothing, allowed=nothing)

Describes a single option accepted by a backend.

- `type`: expected Julia type for the value (e.g. `Real`, `Symbol`, `Bool`).
- `required`: if `true`, the caller must supply this key; `default` must be `nothing`.
- `default`: fill-in value for omitted optional keys. `nothing` is the "required
  sentinel" — it means no default will be filled in (the only legal value when
  `required=true`).
- `allowed`: a `Tuple` of legal values, or `nothing` for unrestricted.
"""
struct BackendOptionSpec
    name::Symbol
    type::Type
    required::Bool
    default::Any
    allowed::Union{Nothing,Tuple}

    function BackendOptionSpec(
        name::Symbol,
        type::Type;
        required::Bool=false,
        default=nothing,
        allowed::Union{Nothing,Tuple}=nothing,
    )
        required && default !== nothing && throw(ArgumentError(
            "BackendOptionSpec :$name is required; `default` must be `nothing`",
        ))
        allowed !== nothing && default !== nothing && !(default in allowed) && throw(
            ArgumentError(
                "BackendOptionSpec :$name default $(repr(default)) is not in allowed set $allowed",
            ),
        )
        new(name, type, required, default, allowed)
    end
end

"""
    BackendOptionsSchema(; backend, version=1, options=[], conflicts=[])

Schema for the `options` NamedTuple accepted by a named backend.

Draft: opt-in, not yet wired into the backend registry (create_*/resolve_*).

- `backend`: the backend name (`:symbol`) this schema describes.
- `version`: schema version integer, used for migration (`>= 1`).
- `options`: `Vector{BackendOptionSpec}` listing every accepted key.
- `conflicts`: `Vector{NTuple{2,Symbol}}` — pairs of option names that must not
  both appear in the same call.
"""
struct BackendOptionsSchema
    backend::Symbol
    version::Int
    options::Vector{BackendOptionSpec}
    conflicts::Vector{NTuple{2,Symbol}}

    function BackendOptionsSchema(;
        backend::Union{Symbol,AbstractString},
        version::Int=1,
        options::Vector{BackendOptionSpec}=BackendOptionSpec[],
        conflicts::Vector{NTuple{2,Symbol}}=NTuple{2,Symbol}[],
    )
        version >= 1 || throw(ArgumentError("BackendOptionsSchema version must be >= 1"))
        names = [s.name for s in options]
        allunique(names) ||
            throw(ArgumentError("BackendOptionsSchema :$(Symbol(backend)) has duplicate option names"))
        new(Symbol(backend), version, options, conflicts)
    end
end

"""
    validate_backend_options(schema, options::NamedTuple) -> NamedTuple

Validate a raw `options` NamedTuple against `schema`.

Checks (in order): unknown keys, missing required keys, type mismatches,
allowed-set violations, mutual-exclusion conflicts.

On success returns a normalized NamedTuple in schema declaration order with
defaults filled in for any omitted optional key whose `default` is not `nothing`.

Throws `ArgumentError` on the first violation encountered.
"""
function validate_backend_options(
    schema::BackendOptionsSchema,
    options::NamedTuple,
)::NamedTuple
    known = Set(s.name for s in schema.options)
    for k in keys(options)
        k in known || throw(ArgumentError(
            "backend :$(schema.backend): unknown option :$k",
        ))
    end
    for spec in schema.options
        if haskey(options, spec.name)
            val = options[spec.name]
            val isa spec.type || throw(ArgumentError(
                "backend :$(schema.backend): option :$(spec.name) expected $(spec.type)," *
                " got $(typeof(val))",
            ))
            if spec.allowed !== nothing
                val in spec.allowed || throw(ArgumentError(
                    "backend :$(schema.backend): option :$(spec.name) value $(repr(val))" *
                    " is not in allowed set $(spec.allowed)",
                ))
            end
        elseif spec.required
            throw(ArgumentError(
                "backend :$(schema.backend): required option :$(spec.name) is missing",
            ))
        end
    end
    for (a, b) in schema.conflicts
        if haskey(options, a) && haskey(options, b)
            throw(ArgumentError(
                "backend :$(schema.backend): options :$a and :$b are mutually exclusive",
            ))
        end
    end
    pairs = Pair{Symbol,Any}[]
    for spec in schema.options
        if haskey(options, spec.name)
            push!(pairs, spec.name => options[spec.name])
        elseif !spec.required && spec.default !== nothing
            push!(pairs, spec.name => spec.default)
        end
    end
    return NamedTuple(pairs)
end

"""
    validate_backend_options(schema, spec::OrbitBackendSpec) -> NamedTuple

Convenience: validate `spec.options` against `schema`, asserting `spec.name == schema.backend`.
"""
function validate_backend_options(
    schema::BackendOptionsSchema,
    spec::OrbitBackendSpec,
)::NamedTuple
    spec.name == schema.backend || throw(ArgumentError(
        "schema is for backend :$(schema.backend), but spec is for :$(spec.name)",
    ))
    validate_backend_options(schema, spec.options)
end

"""
    validate_backend_options(schema, spec::ComputeBackendSpec) -> NamedTuple

Convenience: validate `spec.options` against `schema`, asserting `spec.name == schema.backend`.
"""
function validate_backend_options(
    schema::BackendOptionsSchema,
    spec::ComputeBackendSpec,
)::NamedTuple
    spec.name == schema.backend || throw(ArgumentError(
        "schema is for backend :$(schema.backend), but spec is for :$(spec.name)",
    ))
    validate_backend_options(schema, spec.options)
end

"""
    migrate_backend_options(schema, options; from_version, renames=Dict{Symbol,Symbol}()) -> NamedTuple

Draft migration stub: carry `options` forward from `from_version` to `schema.version`.

- `from_version == schema.version`: no-op, returns `options` unchanged.
- `from_version > schema.version`: throws `ArgumentError` (cannot migrate backwards).
- Otherwise applies `renames` (old key => new key) and returns the updated NamedTuple.
  Keys not listed in `renames` are kept as-is. Richer transformations (value coercions,
  key removal, multi-hop paths) are future work.
"""
function migrate_backend_options(
    schema::BackendOptionsSchema,
    options::NamedTuple;
    from_version::Int,
    renames::Dict{Symbol,Symbol}=Dict{Symbol,Symbol}(),
)::NamedTuple
    from_version > schema.version && throw(ArgumentError(
        "backend :$(schema.backend): cannot migrate backwards" *
        " (from_version=$from_version > schema.version=$(schema.version))",
    ))
    from_version == schema.version && return options
    isempty(renames) && return options
    pairs = Pair{Symbol,Any}[]
    for k in keys(options)
        push!(pairs, get(renames, k, k) => options[k])
    end
    return NamedTuple(pairs)
end

end

# Admission control: resource profiles and the initial runtime limits from the
# design (section 10). Admission is enforced in the application service before a
# job is ever persisted, so oversize or out-of-policy work never reaches a store
# or a worker.

using SatelliteSimCore: resolve_constellation, WalkerConstellationConfig

"""A named, CPU-only resource profile with a hard wall-clock timeout."""
struct ResourceProfile
    name::String
    cpu_millicores::Int
    memory_mib::Int
    timeout_seconds::Int
    concurrency_weight::Int
end

"""The only profiles offered by the Phase 2 runtime; both are CPU-only."""
const RESOURCE_PROFILES = Dict{String,ResourceProfile}(
    "small" => ResourceProfile("small", 2_000, 8_192, 15 * 60, 1),
    "standard" => ResourceProfile("standard", 6_000, 49_152, 60 * 60, 2),
)

const DEFAULT_RESOURCE_PROFILE = "small"

# Initial runtime limits (design section 10).
const MAX_REQUEST_BODY_BYTES = 256 * 1024
const MAX_NORMALIZED_CONFIG_BYTES = 256 * 1024
const MAX_STEPS = 2_000
const MAX_SATELLITES = 2_048
const MAX_T_TIMES_STEPS = 2_000_000
const MAX_HORIZON_SECONDS = 7 * 24 * 60 * 60
const MAX_RUNNER_LOG_BYTES = 2 * 1024 * 1024
const MAX_READ_RESULT_BYTES = 256 * 1024
const MAX_ARTIFACT_RESERVATION_BYTES = 1024 * 1024 * 1024
const MAX_ATTEMPTS = 2
const TENANT_CONCURRENCY_CAP = 2

"""Deterministic, bounded summary of an admission decision for one config."""
struct AdmissionEstimate
    steps::Int
    satellites::Int
    horizon_seconds::Float64
    normalized_config_bytes::Int
    profile::String
end

"""A scheduler-agnostic resource request derived from a profile (no Kubernetes types)."""
struct RuntimeResources
    cpu_millicores::Int
    memory_mib::Int
end

"""Resolve a profile name to its definition or reject it."""
function resource_profile(name::AbstractString)::ResourceProfile
    profile = get(RESOURCE_PROFILES, String(name), nothing)
    profile === nothing && throw(RuntimeError(
        "RUNTIME_POLICY_REJECTED",
        "unknown resource profile '$(String(name))'; supported profiles are $(join(sort!(collect(keys(RESOURCE_PROFILES))), ", "))",
    ))
    return profile
end

"""Map a profile onto a generic resource request DTO."""
to_resources(profile::ResourceProfile) =
    RuntimeResources(profile.cpu_millicores, profile.memory_mib)

"""
Resolve the real satellite count of a config's constellation. An explicit
constellation object carries `T` directly; a named constellation is resolved
through the shared catalog, and unknown names or catalog entries without a
static satellite count (e.g. TLE-file constellations) are rejected.
"""
function _satellite_count(normalized::AbstractDict)::Int
    constellation = get(normalized, "constellation", nothing)
    if constellation isa AbstractDict
        value = get(constellation, "T", nothing)
        value isa Integer || throw(RuntimeError("RUNTIME_POLICY_REJECTED",
            "constellation object does not declare an integer satellite count T"))
        return Int(value)
    end
    constellation isa AbstractString || throw(RuntimeError("RUNTIME_POLICY_REJECTED",
        "constellation must be a named catalog entry or an explicit Walker object"))
    config = try
        resolve_constellation(Symbol(String(constellation)))
    catch
        throw(RuntimeError("RUNTIME_POLICY_REJECTED",
            "unknown named constellation '$(String(constellation))'"))
    end
    config isa WalkerConstellationConfig || throw(RuntimeError("RUNTIME_POLICY_REJECTED",
        "named constellation '$(String(constellation))' has no static satellite count and cannot be admitted"))
    return config.T
end

function _horizon_seconds(normalized::AbstractDict)::Float64
    tspan = get(normalized, "tspan", nothing)
    (tspan isa AbstractVector && length(tspan) == 2) || return 0.0
    return Float64(tspan[2]) - Float64(tspan[1])
end

"""
    enforce_admission(normalized, profile) -> AdmissionEstimate

Apply every runtime limit to a normalized config. The satellite count is
always resolved to a real value first (explicit `T` or catalog lookup), so
satellite-dependent limits are never skipped.
"""
function enforce_admission(normalized::AbstractDict, profile::ResourceProfile)::AdmissionEstimate
    config_bytes = ncodeunits(JSON.json(normalized))
    config_bytes <= MAX_NORMALIZED_CONFIG_BYTES || throw(RuntimeError(
        "RUNTIME_POLICY_REJECTED",
        "normalized config is $config_bytes bytes; limit is $MAX_NORMALIZED_CONFIG_BYTES bytes",
    ))
    steps = Int(get(normalized, "steps", 0))
    steps <= MAX_STEPS || throw(RuntimeError(
        "RUNTIME_POLICY_REJECTED",
        "steps is $steps; limit is $MAX_STEPS",
    ))
    horizon = _horizon_seconds(normalized)
    horizon <= MAX_HORIZON_SECONDS || throw(RuntimeError(
        "RUNTIME_POLICY_REJECTED",
        "simulation horizon is $(horizon) s; limit is $MAX_HORIZON_SECONDS s",
    ))
    satellites = _satellite_count(normalized)
    satellites <= MAX_SATELLITES || throw(RuntimeError(
        "RUNTIME_POLICY_REJECTED",
        "constellation has $satellites satellites; limit is $MAX_SATELLITES",
    ))
    satellites * steps <= MAX_T_TIMES_STEPS || throw(RuntimeError(
        "RUNTIME_POLICY_REJECTED",
        "satellites * steps is $(satellites * steps); limit is $MAX_T_TIMES_STEPS",
    ))
    return AdmissionEstimate(steps, satellites, horizon, config_bytes, profile.name)
end

"""Serialize an admission estimate into a stable, public data map."""
function admission_estimate_data(estimate::AdmissionEstimate)
    return Dict{String,Any}(
        "steps" => estimate.steps,
        "satellites" => estimate.satellites,
        "horizon_seconds" => estimate.horizon_seconds,
        "normalized_config_bytes" => estimate.normalized_config_bytes,
        "profile" => estimate.profile,
    )
end

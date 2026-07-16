# Admission control: resource profiles and the initial runtime limits from the
# design (section 10). Admission is enforced in the application service before a
# job is ever persisted, so oversize or out-of-policy work never reaches a store
# or a worker.

using SatelliteSimPlatformKubernetes: KubernetesResources

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
    satellites::Union{Nothing,Int}
    horizon_seconds::Float64
    normalized_config_bytes::Int
    profile::String
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

"""Map a profile onto the shared, validated scheduler resource units."""
to_k8s_resources(profile::ResourceProfile) =
    KubernetesResources(profile.cpu_millicores, profile.memory_mib)

function _satellite_count(normalized::AbstractDict)::Union{Nothing,Int}
    constellation = get(normalized, "constellation", nothing)
    constellation isa AbstractDict || return nothing
    value = get(constellation, "T", nothing)
    value isa Integer ? Int(value) : nothing
end

function _horizon_seconds(normalized::AbstractDict)::Float64
    tspan = get(normalized, "tspan", nothing)
    (tspan isa AbstractVector && length(tspan) == 2) || return 0.0
    return Float64(tspan[2]) - Float64(tspan[1])
end

"""
    enforce_admission(normalized, profile) -> AdmissionEstimate

Apply every runtime limit that can be decided from a normalized config. Limits
that depend on an explicit satellite count are skipped for named constellations
whose satellite count is not expressed in the document.
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
    if satellites !== nothing
        satellites <= MAX_SATELLITES || throw(RuntimeError(
            "RUNTIME_POLICY_REJECTED",
            "constellation has $satellites satellites; limit is $MAX_SATELLITES",
        ))
        satellites * steps <= MAX_T_TIMES_STEPS || throw(RuntimeError(
            "RUNTIME_POLICY_REJECTED",
            "satellites * steps is $(satellites * steps); limit is $MAX_T_TIMES_STEPS",
        ))
    end
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

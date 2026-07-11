module SatelliteSimPlatformControl

using Dates
using PlatformRunner: validate_experiment_config, PlatformConfigError
using SatelliteSimPlatformKubernetes
using SatelliteSimPlatformStorage

export AbstractIdentityVerifier,
       StaticIdentityVerifier,
       AuthenticatedPrincipal,
       AuthorizationError,
       authenticate,
       authorize_submission!,
       AbstractQuotaStore,
       InMemoryQuotaStore,
       QuotaPolicy,
       QuotaReservation,
       QuotaUsage,
       QuotaError,
       set_quota_policy!,
       reserve_quota!,
       release_quota!,
       usage_snapshot,
       PlatformControlPlane,
       SubmissionReceipt,
       ControlPlaneError,
       submit_experiment!,
       get_submission,
       list_submissions,
       sync_submission!,
       cancel_submission!

"""The caller could not be authenticated or is not permitted to submit work."""
struct AuthorizationError <: Exception
    message::String
end
Base.showerror(io::IO, error::AuthorizationError) = print(io, error.message)

"""The requested reservation exceeds the tenant policy or conflicts with an existing reservation."""
struct QuotaError <: Exception
    message::String
end
Base.showerror(io::IO, error::QuotaError) = print(io, error.message)

"""The edge composition failed after authentication but before a valid submission receipt was created."""
struct ControlPlaneError <: Exception
    message::String
end
Base.showerror(io::IO, error::ControlPlaneError) = print(io, error.message)

"""Verified identity passed in by an adapter; no credential material is retained here."""
struct AuthenticatedPrincipal
    tenant_id::String
    subject::String
    roles::Set{Symbol}
    function AuthenticatedPrincipal(tenant_id::AbstractString, subject::AbstractString, roles)
        tenant = String(tenant_id)
        occursin(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", tenant) ||
            throw(AuthorizationError("tenant_id must be a lowercase DNS label"))
        ncodeunits(tenant) <= 63 || throw(AuthorizationError("tenant_id must be at most 63 bytes"))
        subject_text = strip(String(subject))
        isempty(subject_text) && throw(AuthorizationError("subject must not be empty"))
        ncodeunits(subject_text) <= 128 || throw(AuthorizationError("subject must be at most 128 bytes"))
        role_set = Set(Symbol(role) for role in roles)
        isempty(role_set) && throw(AuthorizationError("principal must have at least one role"))
        all(role -> role in Set([:submit, :read, :admin]), role_set) ||
            throw(AuthorizationError("principal has an unsupported role"))
        return new(tenant, subject_text, role_set)
    end
end

"""Authentication adapter boundary. Production OIDC/mTLS adapters must verify claims externally."""
abstract type AbstractIdentityVerifier end

"""
Development-only identity resolver. Its mapping keys are local identity references,
not production API keys; production callers must supply a real verifier adapter.
"""
struct StaticIdentityVerifier <: AbstractIdentityVerifier
    principals::Dict{String,AuthenticatedPrincipal}
end
function StaticIdentityVerifier(principals::AbstractDict)
    mapped = Dict{String,AuthenticatedPrincipal}()
    for (identity, principal) in principals
        identity isa AbstractString || throw(AuthorizationError("static identity reference must be a string"))
        isempty(strip(identity)) && throw(AuthorizationError("static identity reference must not be empty"))
        principal isa AuthenticatedPrincipal || throw(AuthorizationError("static identity mapping values must be AuthenticatedPrincipal"))
        mapped[String(identity)] = principal
    end
    return StaticIdentityVerifier(mapped)
end

function authenticate(verifier::AbstractIdentityVerifier, presented_identity::AbstractString)
    throw(MethodError(authenticate, (verifier, presented_identity)))
end
function authenticate(verifier::StaticIdentityVerifier, presented_identity::AbstractString)::AuthenticatedPrincipal
    principal = get(verifier.principals, String(presented_identity), nothing)
    principal === nothing && throw(AuthorizationError("identity is not recognized by the configured verifier"))
    return principal
end

"""Require submit/admin authority; tenant scoping occurs through the verified principal."""
function authorize_submission!(principal::AuthenticatedPrincipal)::AuthenticatedPrincipal
    (:submit in principal.roles || :admin in principal.roles) ||
        throw(AuthorizationError("principal '$(principal.subject)' is not allowed to submit experiments"))
    return principal
end

"""Per-tenant policy used for admission-time reservations, not post-hoc billing."""
struct QuotaPolicy
    max_concurrent_jobs::Int
    max_cpu_millicores::Int
    max_memory_mib::Int
    max_daily_jobs::Int
    max_artifact_bytes::Int
    function QuotaPolicy(; max_concurrent_jobs::Integer,
                           max_cpu_millicores::Integer,
                           max_memory_mib::Integer,
                           max_daily_jobs::Integer,
                           max_artifact_bytes::Integer)
        all(value -> value >= 0, (
            max_concurrent_jobs, max_cpu_millicores, max_memory_mib,
            max_daily_jobs, max_artifact_bytes,
        )) || throw(QuotaError("quota policy limits must be non-negative"))
        return new(
            Int(max_concurrent_jobs), Int(max_cpu_millicores), Int(max_memory_mib),
            Int(max_daily_jobs), Int(max_artifact_bytes),
        )
    end
end

"""A reservation is tenant-scoped and idempotent by `(tenant_id, job_id)`."""
mutable struct QuotaReservation
    tenant_id::String
    job_id::String
    resources::KubernetesResources
    artifact_bytes::Int
    submitted_at_utc::DateTime
    state::Symbol
    released_at_utc::Union{Nothing,DateTime}
end

"""Current reservation usage for one tenant at one instant."""
struct QuotaUsage
    concurrent_jobs::Int
    cpu_millicores::Int
    memory_mib::Int
    daily_jobs::Int
    artifact_bytes::Int
end

abstract type AbstractQuotaStore end

"""In-memory quota store for local development and deterministic tests; it is not a distributed lease store."""
mutable struct InMemoryQuotaStore <: AbstractQuotaStore
    policies::Dict{String,QuotaPolicy}
    reservations::Dict{Tuple{String,String},QuotaReservation}
end
InMemoryQuotaStore() = InMemoryQuotaStore(Dict{String,QuotaPolicy}(), Dict{Tuple{String,String},QuotaReservation}())

function set_quota_policy!(store::AbstractQuotaStore, tenant_id::AbstractString, policy::QuotaPolicy)
    throw(MethodError(set_quota_policy!, (store, tenant_id, policy)))
end
function set_quota_policy!(store::InMemoryQuotaStore, tenant_id::AbstractString, policy::QuotaPolicy)::QuotaPolicy
    tenant = AuthenticatedPrincipal(tenant_id, "policy-admin", [:admin]).tenant_id
    store.policies[tenant] = policy
    return policy
end

function _job_id(value::AbstractString)
    id = String(value)
    occursin(r"^[A-Za-z0-9_-]{1,128}$", id) ||
        throw(QuotaError("job_id must use 1-128 ASCII letters, digits, '_' or '-'"))
    return id
end

function _usage(store::InMemoryQuotaStore, tenant::String; at_utc::DateTime=now(UTC))::QuotaUsage
    current_day = Date(at_utc)
    active = (reservation for reservation in values(store.reservations)
              if reservation.tenant_id == tenant && reservation.state == :active)
    active_values = collect(active)
    daily_jobs = count(
        reservation -> reservation.tenant_id == tenant && Date(reservation.submitted_at_utc) == current_day,
        values(store.reservations),
    )
    return QuotaUsage(
        length(active_values),
        sum(reservation -> reservation.resources.cpu_millicores, active_values; init=0),
        sum(reservation -> reservation.resources.memory_mib, active_values; init=0),
        daily_jobs,
        sum(reservation -> reservation.artifact_bytes, active_values; init=0),
    )
end

function usage_snapshot(store::AbstractQuotaStore, tenant_id::AbstractString; at_utc::DateTime=now(UTC))
    throw(MethodError(usage_snapshot, (store, tenant_id)))
end
function usage_snapshot(store::InMemoryQuotaStore, tenant_id::AbstractString; at_utc::DateTime=now(UTC))::QuotaUsage
    tenant = AuthenticatedPrincipal(tenant_id, "usage-reader", [:read]).tenant_id
    return _usage(store, tenant; at_utc=at_utc)
end

function reserve_quota!(store::AbstractQuotaStore, principal::AuthenticatedPrincipal, job_id::AbstractString,
                        resources::KubernetesResources; artifact_bytes::Integer=0, now_utc::DateTime=now(UTC))
    throw(MethodError(reserve_quota!, (store, principal, job_id, resources)))
end
function reserve_quota!(store::InMemoryQuotaStore, principal::AuthenticatedPrincipal, job_id::AbstractString,
                        resources::KubernetesResources; artifact_bytes::Integer=0, now_utc::DateTime=now(UTC))::QuotaReservation
    authorize_submission!(principal)
    artifact_bytes >= 0 || throw(QuotaError("artifact_bytes must be non-negative"))
    id = _job_id(job_id)
    key = (principal.tenant_id, id)
    existing = get(store.reservations, key, nothing)
    if existing !== nothing
        existing.resources == resources && existing.artifact_bytes == artifact_bytes ||
            throw(QuotaError("job '$id' already has a different quota reservation"))
        return existing
    end
    policy = get(store.policies, principal.tenant_id, nothing)
    policy === nothing && throw(QuotaError("tenant '$(principal.tenant_id)' has no quota policy"))
    usage = _usage(store, principal.tenant_id; at_utc=now_utc)
    usage.concurrent_jobs + 1 <= policy.max_concurrent_jobs || throw(QuotaError("concurrent job quota exceeded"))
    usage.cpu_millicores + resources.cpu_millicores <= policy.max_cpu_millicores || throw(QuotaError("CPU quota exceeded"))
    usage.memory_mib + resources.memory_mib <= policy.max_memory_mib || throw(QuotaError("memory quota exceeded"))
    usage.daily_jobs + 1 <= policy.max_daily_jobs || throw(QuotaError("daily job quota exceeded"))
    usage.artifact_bytes + Int(artifact_bytes) <= policy.max_artifact_bytes || throw(QuotaError("artifact byte quota exceeded"))
    reservation = QuotaReservation(principal.tenant_id, id, resources, Int(artifact_bytes), now_utc, :active, nothing)
    store.reservations[key] = reservation
    return reservation
end

function release_quota!(store::AbstractQuotaStore, reservation::QuotaReservation; now_utc::DateTime=now(UTC))
    throw(MethodError(release_quota!, (store, reservation)))
end
function release_quota!(store::InMemoryQuotaStore, reservation::QuotaReservation; now_utc::DateTime=now(UTC))::QuotaReservation
    key = (reservation.tenant_id, reservation.job_id)
    stored = get(store.reservations, key, nothing)
    stored === reservation || throw(QuotaError("quota reservation is not owned by this store"))
    if stored.state == :active
        stored.state = :released
        stored.released_at_utc = now_utc
    end
    return stored
end

"""Composes edge identity/quota checks, object storage namespaces, and constrained Kubernetes submission."""
mutable struct PlatformControlPlane{V<:AbstractIdentityVerifier,Q<:AbstractQuotaStore,S<:AbstractExperimentStorage,K<:AbstractKubernetesJobClient}
    identity_verifier::V
    quota_store::Q
    storage::S
    kubernetes_client::K
    namespace::String
    image::String
    service_account::String
    ttl_seconds_after_finished::Int
    backoff_limit::Int
    submissions::Dict{Tuple{String,String},Any}
end

function PlatformControlPlane(identity_verifier::V, quota_store::Q, storage::S, kubernetes_client::K;
                              namespace::AbstractString="satellitesim",
                              image::AbstractString,
                              service_account::AbstractString="satellitesim-runner",
                              ttl_seconds_after_finished::Integer=3600,
                              backoff_limit::Integer=0) where {V<:AbstractIdentityVerifier,Q<:AbstractQuotaStore,S<:AbstractExperimentStorage,K<:AbstractKubernetesJobClient}
    # Let the renderer constructor own all public Kubernetes validation in one place.
    template = KubernetesJobSpec(
        job_id="validation",
        namespace=namespace,
        image=image,
        service_account=service_account,
        config_key="validation/config.json",
        output_prefix="validation/output",
        ttl_seconds_after_finished=ttl_seconds_after_finished,
        backoff_limit=backoff_limit,
    )
    return PlatformControlPlane{V,Q,S,K}(
        identity_verifier, quota_store, storage, kubernetes_client,
        template.namespace, template.image, template.service_account,
        template.ttl_seconds_after_finished, template.backoff_limit,
        Dict{Tuple{String,String},Any}(),
    )
end

"""Stable edge-level receipt; raw credentials and arbitrary PodSpec never appear here."""
mutable struct SubmissionReceipt
    tenant_id::String
    subject::String
    job_id::String
    config_key::String
    output_prefix::String
    kubernetes_job_name::String
    state::Symbol
    quota_reservation::QuotaReservation
end

_submission_key(principal::AuthenticatedPrincipal, job_id::String) = (principal.tenant_id, job_id)
_config_key(tenant::String, job_id::String) = "tenants/$tenant/configs/$job_id.json"
_output_prefix(tenant::String, job_id::String) = "tenants/$tenant/jobs/$job_id"

function _existing_submission(plane::PlatformControlPlane, principal::AuthenticatedPrincipal, job_id::String, normalized)
    existing = get(plane.submissions, _submission_key(principal, job_id), nothing)
    existing === nothing && return nothing
    stored = get_json(plane.storage, existing.config_key)
    stored == normalized || throw(ControlPlaneError("idempotency key '$job_id' was reused with a different experiment config"))
    return existing::SubmissionReceipt
end

"""
    submit_experiment!(plane, presented_identity, raw_config; idempotency_key, resources, artifact_bytes=0)

Authenticate at the edge, validate the public Runner config, reserve tenant quota,
write an isolated config object, and submit only a constrained Kubernetes Job.
"""
function submit_experiment!(plane::PlatformControlPlane, presented_identity::AbstractString, raw_config;
                             idempotency_key::AbstractString,
                             resources::KubernetesResources=KubernetesResources(1000, 2048),
                             artifact_bytes::Integer=0,
                             request_id::Union{Nothing,AbstractString}=nothing)::SubmissionReceipt
    principal = authorize_submission!(authenticate(plane.identity_verifier, presented_identity))
    job_id = _job_id(idempotency_key)
    normalized = try
        validate_experiment_config(raw_config)
    catch error
        error isa PlatformConfigError || rethrow()
        throw(ControlPlaneError("experiment config rejected: $(error.message)"))
    end
    existing = _existing_submission(plane, principal, job_id, normalized)
    existing === nothing || return existing

    config_key = _config_key(principal.tenant_id, job_id)
    output_prefix = _output_prefix(principal.tenant_id, job_id)
    annotations = request_id === nothing ? nothing : Dict("satellitesim.io/request-id" => String(request_id))
    kubernetes_job_id = "$(principal.tenant_id)-$(job_id)"
    spec = KubernetesJobSpec(
        job_id=kubernetes_job_id,
        namespace=plane.namespace,
        image=plane.image,
        service_account=plane.service_account,
        config_key=config_key,
        output_prefix=output_prefix,
        resources=resources,
        ttl_seconds_after_finished=plane.ttl_seconds_after_finished,
        backoff_limit=plane.backoff_limit,
        labels=Dict("satellitesim.io/tenant" => principal.tenant_id),
        annotations=annotations,
    )
    rendered = render_job(spec)
    reservation = reserve_quota!(plane.quota_store, principal, job_id, resources; artifact_bytes=artifact_bytes)
    try
        put_json!(plane.storage, config_key, normalized)
        kubernetes_record = submit_job!(plane.kubernetes_client, rendered)
        receipt = SubmissionReceipt(
            principal.tenant_id, principal.subject, job_id, config_key, output_prefix,
            kubernetes_record.name, kubernetes_record.state, reservation,
        )
        plane.submissions[_submission_key(principal, job_id)] = receipt
        return receipt
    catch
        release_quota!(plane.quota_store, reservation)
        rethrow()
    end
end

function get_submission(plane::PlatformControlPlane, tenant_id::AbstractString, job_id::AbstractString)::Union{SubmissionReceipt,Nothing}
    tenant = AuthenticatedPrincipal(tenant_id, "submission-reader", [:read]).tenant_id
    return get(plane.submissions, (tenant, _job_id(job_id)), nothing)
end

function list_submissions(plane::PlatformControlPlane; tenant_id::Union{Nothing,AbstractString}=nothing)::Vector{SubmissionReceipt}
    records = SubmissionReceipt[value for value in values(plane.submissions)]
    if tenant_id !== nothing
        tenant = AuthenticatedPrincipal(tenant_id, "submission-reader", [:read]).tenant_id
        filter!(receipt -> receipt.tenant_id == tenant, records)
    end
    sort!(records; by=receipt -> (receipt.tenant_id, receipt.job_id))
    return records
end

"""Synchronize a receipt with its Kubernetes adapter and release quota on terminal states."""
function sync_submission!(plane::PlatformControlPlane, receipt::SubmissionReceipt)::SubmissionReceipt
    record = get_job_status(plane.kubernetes_client, receipt.kubernetes_job_name)
    record === nothing && throw(ControlPlaneError("Kubernetes Job '$(receipt.kubernetes_job_name)' no longer exists"))
    receipt.state = record.state
    receipt.state in Set([:succeeded, :failed, :cancelled]) &&
        release_quota!(plane.quota_store, receipt.quota_reservation)
    return receipt
end

function cancel_submission!(plane::PlatformControlPlane, receipt::SubmissionReceipt)::SubmissionReceipt
    cancel_job!(plane.kubernetes_client, receipt.kubernetes_job_name)
    return sync_submission!(plane, receipt)
end

end # module

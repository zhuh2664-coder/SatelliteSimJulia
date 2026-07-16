# Transport-neutral Runtime Application Service. It owns every business rule:
# authentication boundary (a bounded principal DTO is injected, never a token),
# validation, admission, idempotency, quota, job lifecycle, artifact
# authorization and reproduction lineage. A transport adapter maps requests to
# these calls and maps `RuntimeError` to the wire envelope; it holds no rules.

using Dates
using JSON
using SHA
using UUIDs
using PlatformRunner: validate_experiment_config, PlatformConfigError, EXPERIMENT_SCHEMA_VERSION
using SatelliteSimPlatformControl: AuthenticatedPrincipal, authorize_submission!, AuthorizationError
using SatelliteSimPlatformStorage: AbstractExperimentStorage, put_json!, get_json, get_bytes, has_object

mutable struct RuntimeApplicationService{S<:AbstractExperimentStorage,B<:AbstractExecutionBackend}
    store::RuntimeJobStore
    storage::S
    backend::B
    release_sha::String
    image_digest::String
    control_plane_version::String
    clock::Function
end

function RuntimeApplicationService(store::RuntimeJobStore, storage::AbstractExperimentStorage,
                                   backend::AbstractExecutionBackend;
                                   release_sha::AbstractString="deterministic-test-release",
                                   image_digest::AbstractString="sha256:" * repeat("0", 64),
                                   control_plane_version::AbstractString="0.1.0",
                                   clock::Function=() -> now(UTC))
    return RuntimeApplicationService(store, storage, backend, String(release_sha),
        String(image_digest), String(control_plane_version), clock)
end

const _IDEMPOTENCY_KEY_PATTERN = r"^[A-Za-z0-9._-]{1,128}$"

# Canonical (recursively key-sorted) serialization so the config hash is stable
# across storage round-trips and independent of Dict iteration order.
function _canonical_json(value)
    if value isa AbstractDict
        pairs = [JSON.json(String(k)) * ":" * _canonical_json(value[k]) for k in sort!(collect(keys(value)); by=String)]
        return "{" * join(pairs, ",") * "}"
    elseif value isa AbstractVector
        return "[" * join((_canonical_json(v) for v in value), ",") * "]"
    else
        return JSON.json(value)
    end
end
_config_sha(normalized) = bytes2hex(sha256(_canonical_json(normalized)))
_new_job_id() = "job-" * replace(string(uuid4()), "-" => "")
_config_key(tenant::AbstractString, job_id::AbstractString) =
    "tenants/$(tenant)/jobs/$(job_id)/config.normalized.json"
_output_prefix(tenant::AbstractString, job_id::AbstractString) =
    "tenants/$(tenant)/jobs/$(job_id)/artifacts"

_ts_opt(dt) = dt === nothing ? nothing : _ts(dt)

function _authorize_submit(principal::AuthenticatedPrincipal)
    try
        authorize_submission!(principal)
    catch error
        error isa AuthorizationError && throw(RuntimeError("FORBIDDEN", error.message))
        rethrow()
    end
    return principal
end

# Reads only require an authenticated principal; tenant scoping is enforced in
# every query, so no principal can observe another tenant's jobs.
_authorize_read(principal::AuthenticatedPrincipal) = principal

function _validate_config(raw)
    try
        return validate_experiment_config(raw)
    catch error
        if error isa PlatformConfigError
            code = occursin("schema_version", error.message) ? "SCHEMA_UNSUPPORTED" : "INVALID_ARGUMENT"
            throw(RuntimeError(code, "experiment config rejected: $(error.message)"))
        end
        rethrow()
    end
end

function _find_by_idempotency(service::RuntimeApplicationService, tenant::AbstractString, key::AbstractString)
    row = _row(service.store,
        "SELECT $_JOB_COLUMNS FROM jobs WHERE tenant_id = ? AND idempotency_key = ?",
        (String(tenant), String(key)))
    return row === nothing ? nothing : _job(row)
end

function _public_job_view(job::RuntimeJob)
    data = Dict{String,Any}(
        "job_id" => job.id,
        "tenant_id" => job.tenant_id,
        "state" => job.state,
        "phase" => job.phase,
        "attempts" => job.attempts,
        "max_attempts" => job.max_attempts,
        "resource_profile" => job.resource_profile,
        "config_sha256" => job.config_sha256,
        "release_sha" => job.release_sha,
        "image_digest" => job.image_digest,
        "submitted_at" => _ts_opt(job.submitted_at),
        "started_at" => _ts_opt(job.started_at),
        "finished_at" => _ts_opt(job.finished_at),
        "parent_job_id" => job.parent_job_id,
        "cancel_requested" => job.cancel_requested_at !== nothing,
    )
    if job.state == "succeeded"
        data["artifact_keys"] = job.artifact_keys
    end
    if job.error_code !== nothing
        data["error"] = Dict{String,Any}("code" => job.error_code, "message" => job.error_message)
    end
    return data
end

# ---- 1. runtime_health ------------------------------------------------------

function runtime_health(service::RuntimeApplicationService)
    probe = backend_probe(service.backend)
    return Dict{String,Any}(
        "status" => "ok",
        "control_plane_version" => service.control_plane_version,
        "schema_version" => EXPERIMENT_SCHEMA_VERSION,
        "release_sha" => service.release_sha,
        "image_digest" => service.image_digest,
        "backend" => get(probe, "kind", "unknown"),
        "worker_available" => get(probe, "available", false),
        "server_time" => _ts(service.clock()),
    )
end

# ---- 2. runtime_capabilities ------------------------------------------------

function runtime_capabilities(service::RuntimeApplicationService)
    profiles = Dict{String,Any}()
    for (name, profile) in RESOURCE_PROFILES
        profiles[name] = Dict{String,Any}(
            "cpu_millicores" => profile.cpu_millicores,
            "memory_mib" => profile.memory_mib,
            "timeout_seconds" => profile.timeout_seconds,
            "concurrency_weight" => profile.concurrency_weight,
        )
    end
    return Dict{String,Any}(
        "schema_versions" => [EXPERIMENT_SCHEMA_VERSION],
        "resource_profiles" => profiles,
        "default_resource_profile" => DEFAULT_RESOURCE_PROFILE,
        "artifact_names" => vcat(RUNNER_ARTIFACT_NAMES, [ARTIFACT_INDEX_NAME]),
        "error_codes" => sort!(collect(RUNTIME_ERROR_CODES)),
        "public_states" => sort!(collect(PUBLIC_STATES)),
        "limits" => Dict{String,Any}(
            "max_request_body_bytes" => MAX_REQUEST_BODY_BYTES,
            "max_normalized_config_bytes" => MAX_NORMALIZED_CONFIG_BYTES,
            "max_steps" => MAX_STEPS,
            "max_satellites" => MAX_SATELLITES,
            "max_satellites_times_steps" => MAX_T_TIMES_STEPS,
            "max_horizon_seconds" => MAX_HORIZON_SECONDS,
            "max_read_result_bytes" => MAX_READ_RESULT_BYTES,
            "max_artifact_reservation_bytes" => MAX_ARTIFACT_RESERVATION_BYTES,
            "max_attempts" => MAX_ATTEMPTS,
            "tenant_concurrency_cap" => TENANT_CONCURRENCY_CAP,
        ),
    )
end

# ---- 3. validate_experiment -------------------------------------------------

function validate_experiment(service::RuntimeApplicationService, principal::AuthenticatedPrincipal, raw_config;
                             resource_profile::AbstractString=DEFAULT_RESOURCE_PROFILE)
    _authorize_read(principal)
    normalized = _validate_config(raw_config)
    profile = SatelliteSimPlatformRuntime.resource_profile(resource_profile)
    estimate = enforce_admission(normalized, profile)
    return Dict{String,Any}(
        "valid" => true,
        "config_sha256" => _config_sha(normalized),
        "normalized_config" => normalized,
        "resource_profile" => profile.name,
        "admission" => admission_estimate_data(estimate),
    )
end

# ---- 4. submit_experiment ---------------------------------------------------

function submit_experiment(service::RuntimeApplicationService, principal::AuthenticatedPrincipal, raw_config;
                           idempotency_key::AbstractString,
                           resource_profile::AbstractString=DEFAULT_RESOURCE_PROFILE,
                           request_id::Union{Nothing,AbstractString}=nothing)
    _authorize_submit(principal)
    occursin(_IDEMPOTENCY_KEY_PATTERN, String(idempotency_key)) || throw(RuntimeError(
        "INVALID_ARGUMENT",
        "idempotency_key must match 1-128 chars of letters, digits, '.', '_' or '-'"))
    normalized = _validate_config(raw_config)
    profile = SatelliteSimPlatformRuntime.resource_profile(resource_profile)
    enforce_admission(normalized, profile)
    return _submit_normalized(service, principal, normalized, profile;
        idempotency_key=idempotency_key, request_id=request_id, parent_job_id=nothing)
end

function _submit_normalized(service::RuntimeApplicationService, principal::AuthenticatedPrincipal,
                            normalized::AbstractDict, profile::ResourceProfile;
                            idempotency_key::AbstractString,
                            request_id::Union{Nothing,AbstractString},
                            parent_job_id::Union{Nothing,AbstractString})
    config_sha = _config_sha(normalized)
    # Fast path: an idempotent replay never writes a new config object.
    existing = _find_by_idempotency(service, principal.tenant_id, idempotency_key)
    if existing !== nothing
        (existing.config_sha256 == config_sha && existing.resource_profile == profile.name) ||
            throw(RuntimeError("IDEMPOTENCY_CONFLICT",
                "idempotency key was reused with a different config or resource profile"))
        data = _public_job_view(existing)
        data["idempotent"] = true
        return data
    end
    job_id = _new_job_id()
    config_key = _config_key(principal.tenant_id, job_id)
    output_prefix = _output_prefix(principal.tenant_id, job_id)
    # Recoverable submit: durable config object first, then the durable job row.
    try
        put_json!(service.storage, config_key, normalized)
    catch
        throw(RuntimeError("STORAGE_UNAVAILABLE", "failed to persist normalized config object"))
    end
    now_utc = service.clock()
    job, created = create_job!(service.store;
        job_id=job_id, tenant_id=principal.tenant_id, subject_id=principal.subject,
        idempotency_key=idempotency_key, config_sha256=config_sha,
        config_storage_key=config_key, output_prefix=output_prefix,
        resource_profile=profile.name, concurrency_weight=profile.concurrency_weight,
        artifact_bytes=MAX_ARTIFACT_RESERVATION_BYTES, release_sha=service.release_sha,
        image_digest=service.image_digest, parent_job_id=parent_job_id,
        request_id=request_id, now_utc=now_utc)
    data = _public_job_view(job)
    data["idempotent"] = !created
    return data
end

# ---- 5. get_job -------------------------------------------------------------

function get_job_view(service::RuntimeApplicationService, principal::AuthenticatedPrincipal,
                      job_id::AbstractString)
    _authorize_read(principal)
    job = get_job(service.store, principal.tenant_id, job_id)
    job === nothing && throw(RuntimeError("JOB_NOT_FOUND", "job '$(String(job_id))' was not found"))
    return _public_job_view(job)
end

# ---- 6. list_jobs -----------------------------------------------------------

function list_jobs_view(service::RuntimeApplicationService, principal::AuthenticatedPrincipal;
                        state::Union{Nothing,AbstractString}=nothing,
                        limit::Integer=20, offset::Integer=0)
    _authorize_read(principal)
    jobs = list_jobs(service.store, principal.tenant_id; state=state, limit=limit, offset=offset)
    return Dict{String,Any}(
        "jobs" => [_public_job_view(job) for job in jobs],
        "limit" => clamp(Int(limit), 1, 100),
        "offset" => max(Int(offset), 0),
        "count" => length(jobs),
    )
end

# ---- 7. cancel_job ----------------------------------------------------------

function cancel_job(service::RuntimeApplicationService, principal::AuthenticatedPrincipal,
                    job_id::AbstractString; request_id::Union{Nothing,AbstractString}=nothing)
    _authorize_submit(principal)
    job = request_cancel!(service.store, principal.tenant_id, job_id;
        request_id=request_id, now_utc=service.clock())
    return _public_job_view(job)
end

# ---- 8. get_artifacts -------------------------------------------------------

function get_artifacts(service::RuntimeApplicationService, principal::AuthenticatedPrincipal,
                       job_id::AbstractString)
    _authorize_read(principal)
    job = get_job(service.store, principal.tenant_id, job_id)
    job === nothing && throw(RuntimeError("JOB_NOT_FOUND", "job '$(String(job_id))' was not found"))
    job.state == "succeeded" || throw(RuntimeError("ARTIFACT_NOT_READY",
        "job '$(job.id)' is $(job.state); artifacts are available only for succeeded jobs"))
    index_key = "$(job.output_prefix)/$(ARTIFACT_INDEX_NAME)"
    has_object(service.storage, index_key) || throw(RuntimeError("ARTIFACT_NOT_FOUND",
        "artifact index for job '$(job.id)' was not found"))
    index = get_json(service.storage, index_key)
    return Dict{String,Any}(
        "job_id" => job.id,
        "output_prefix" => job.output_prefix,
        "artifact_keys" => job.artifact_keys,
        "artifacts" => get(index, "artifacts", Any[]),
    )
end

# ---- 9. read_result ---------------------------------------------------------

function read_result(service::RuntimeApplicationService, principal::AuthenticatedPrincipal,
                     job_id::AbstractString; max_bytes::Integer=MAX_READ_RESULT_BYTES)
    _authorize_read(principal)
    job = get_job(service.store, principal.tenant_id, job_id)
    job === nothing && throw(RuntimeError("JOB_NOT_FOUND", "job '$(String(job_id))' was not found"))
    job.state == "succeeded" || throw(RuntimeError("ARTIFACT_NOT_READY",
        "job '$(job.id)' is $(job.state); results are available only for succeeded jobs"))
    result_key = "$(job.output_prefix)/result.json"
    has_object(service.storage, result_key) || throw(RuntimeError("ARTIFACT_NOT_FOUND",
        "result.json for job '$(job.id)' was not found"))
    bytes = get_bytes(service.storage, result_key)
    limit = clamp(Int(max_bytes), 1, MAX_READ_RESULT_BYTES)
    length(bytes) <= limit || throw(RuntimeError("ARTIFACT_TOO_LARGE",
        "result.json is $(length(bytes)) bytes; limit is $limit bytes"))
    return Dict{String,Any}(
        "job_id" => job.id,
        "bytes" => length(bytes),
        "result" => JSON.parse(String(bytes)),
    )
end

# ---- 10. reproduce_job ------------------------------------------------------

function reproduce_job(service::RuntimeApplicationService, principal::AuthenticatedPrincipal,
                       source_job_id::AbstractString;
                       idempotency_key::AbstractString,
                       resource_profile::Union{Nothing,AbstractString}=nothing,
                       request_id::Union{Nothing,AbstractString}=nothing)
    _authorize_submit(principal)
    occursin(_IDEMPOTENCY_KEY_PATTERN, String(idempotency_key)) || throw(RuntimeError(
        "INVALID_ARGUMENT",
        "idempotency_key must match 1-128 chars of letters, digits, '.', '_' or '-'"))
    source = get_job(service.store, principal.tenant_id, source_job_id)
    source === nothing && throw(RuntimeError("JOB_NOT_FOUND",
        "source job '$(String(source_job_id))' was not found"))
    has_object(service.storage, source.config_storage_key) || throw(RuntimeError("ARTIFACT_NOT_FOUND",
        "normalized config for source job '$(source.id)' was not found"))
    normalized = get_json(service.storage, source.config_storage_key)
    profile_name = resource_profile === nothing ? source.resource_profile : String(resource_profile)
    profile = SatelliteSimPlatformRuntime.resource_profile(profile_name)
    enforce_admission(normalized, profile)
    return _submit_normalized(service, principal, normalized, profile;
        idempotency_key=idempotency_key, request_id=request_id, parent_job_id=source.id)
end

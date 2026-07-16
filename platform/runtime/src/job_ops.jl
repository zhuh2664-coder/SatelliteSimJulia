# Durable job lifecycle operations. These sit on top of RuntimeJobStore and
# express every multi-row invariant (idempotency, admission concurrency,
# fencing-guarded leases, single-transaction finalization, lease recovery).

# ---- creation / idempotency -------------------------------------------------

"""
    precheck_quota(store, tenant_id, concurrency_weight; concurrency_cap)

Reject a submission that cannot fit the tenant's active-job weight cap before
any side effect (e.g. a storage write) happens. `create_job!` re-checks the
same invariant atomically inside its transaction; this precheck only prevents
avoidable work, it is not the enforcement point.
"""
function precheck_quota(store::RuntimeJobStore, tenant_id::AbstractString,
                        concurrency_weight::Integer;
                        concurrency_cap::Integer=TENANT_CONCURRENCY_CAP)
    active = _row(store,
        "SELECT COALESCE(SUM(concurrency_weight), 0) AS w FROM jobs WHERE tenant_id = ? AND state IN ('queued','running')",
        (String(tenant_id),))
    used = Int(active["w"])
    if used + Int(concurrency_weight) > Int(concurrency_cap)
        throw(RuntimeError("QUOTA_EXCEEDED",
            "tenant active-job capacity exceeded (weight $(used + Int(concurrency_weight)) > cap $(Int(concurrency_cap)))"))
    end
    return nothing
end

"""
    create_job!(store; ...) -> (job::RuntimeJob, created::Bool)

Atomically enforce `(tenant_id, idempotency_key)` idempotency and the tenant
active-job weight cap, then persist the job and its quota reservation. A repeat
of the same key with an identical config and profile returns the original job;
a repeat with a different config or profile raises `IDEMPOTENCY_CONFLICT`.
"""
function create_job!(store::RuntimeJobStore;
                     job_id::AbstractString,
                     tenant_id::AbstractString,
                     subject_id::AbstractString,
                     idempotency_key::AbstractString,
                     config_sha256::AbstractString,
                     config_storage_key::AbstractString,
                     output_prefix::AbstractString,
                     resource_profile::AbstractString,
                     concurrency_weight::Integer,
                     artifact_bytes::Integer,
                     release_sha::AbstractString,
                     image_digest::AbstractString,
                     max_attempts::Integer=MAX_ATTEMPTS,
                     parent_job_id::Union{Nothing,AbstractString}=nothing,
                     request_id::Union{Nothing,AbstractString}=nothing,
                     concurrency_cap::Integer=TENANT_CONCURRENCY_CAP,
                     now_utc::DateTime=now(UTC))
    return transaction(store) do
        existing = _row(store,
            "SELECT $_JOB_COLUMNS FROM jobs WHERE tenant_id = ? AND idempotency_key = ?",
            (String(tenant_id), String(idempotency_key)))
        if existing !== nothing
            job = _job(existing)
            if job.config_sha256 == String(config_sha256) && job.resource_profile == String(resource_profile)
                return (job, false)
            end
            throw(RuntimeError("IDEMPOTENCY_CONFLICT",
                "idempotency key was reused with a different config or resource profile"))
        end
        active = _row(store,
            "SELECT COALESCE(SUM(concurrency_weight), 0) AS w FROM jobs WHERE tenant_id = ? AND state IN ('queued','running')",
            (String(tenant_id),))
        used = Int(active["w"])
        if used + Int(concurrency_weight) > Int(concurrency_cap)
            throw(RuntimeError("QUOTA_EXCEEDED",
                "tenant active-job capacity exceeded (weight $(used + Int(concurrency_weight)) > cap $(Int(concurrency_cap)))"))
        end
        DBInterface.execute(store.db, """
            INSERT INTO jobs(id, tenant_id, subject_id, idempotency_key, config_sha256,
                config_storage_key, output_prefix, resource_profile, concurrency_weight,
                release_sha, image_digest, state, phase, attempts, max_attempts,
                submitted_at, parent_job_id, artifact_keys)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'queued', 'waiting_for_worker', 0, ?, ?, ?, '[]')
        """, (
            String(job_id), String(tenant_id), String(subject_id), String(idempotency_key),
            String(config_sha256), String(config_storage_key), String(output_prefix),
            String(resource_profile), Int(concurrency_weight), String(release_sha),
            String(image_digest), Int(max_attempts), _ts(now_utc),
            parent_job_id === nothing ? missing : String(parent_job_id),
        ))
        DBInterface.execute(store.db, """
            INSERT INTO quota_reservations(tenant_id, job_id, artifact_bytes, concurrency_weight, state, reserved_at)
            VALUES(?, ?, ?, ?, 'active', ?)
        """, (
            String(tenant_id), String(job_id), Int(artifact_bytes),
            Int(concurrency_weight), _ts(now_utc),
        ))
        record_audit!(store; action="submit_experiment", request_id=request_id,
            tenant_id=tenant_id, subject_id=subject_id, job_id=job_id,
            result_code="queued",
            metadata=Dict("resource_profile" => String(resource_profile),
                          "config_sha256" => String(config_sha256)),
            now_utc=now_utc)
        return (_fetch_job(store, job_id), true)
    end
end

# ---- reads ------------------------------------------------------------------

"""Tenant-scoped lookup; a job from another tenant is invisible."""
function get_job(store::RuntimeJobStore, tenant_id::AbstractString, job_id::AbstractString)
    row = _row(store, "SELECT $_JOB_COLUMNS FROM jobs WHERE id = ? AND tenant_id = ?",
        (String(job_id), String(tenant_id)))
    return row === nothing ? nothing : _job(row)
end

function list_jobs(store::RuntimeJobStore, tenant_id::AbstractString;
                   state::Union{Nothing,AbstractString}=nothing,
                   limit::Integer=20, offset::Integer=0)
    bounded = clamp(Int(limit), 1, 100)
    off = max(Int(offset), 0)
    rows = if state === nothing
        _rows(store,
            "SELECT $_JOB_COLUMNS FROM jobs WHERE tenant_id = ? ORDER BY submitted_at DESC, id DESC LIMIT ? OFFSET ?",
            (String(tenant_id), bounded, off))
    else
        is_public_state(state) || throw(RuntimeError("INVALID_ARGUMENT", "unknown job state filter '$(String(state))'"))
        _rows(store,
            "SELECT $_JOB_COLUMNS FROM jobs WHERE tenant_id = ? AND state = ? ORDER BY submitted_at DESC, id DESC LIMIT ? OFFSET ?",
            (String(tenant_id), String(state), bounded, off))
    end
    return [_job(row) for row in rows]
end

# ---- lease / fencing --------------------------------------------------------

"""Claim the oldest queued job, assigning a strictly-increasing fencing token."""
function claim_next_job!(store::RuntimeJobStore;
                         worker_id::AbstractString,
                         lease_seconds::Integer=30,
                         now_utc::DateTime=now(UTC))
    for _ in 1:8
        outcome = transaction(store) do
            pick = _row(store,
                "SELECT id FROM jobs WHERE state = 'queued' ORDER BY submitted_at, id LIMIT 1")
            pick === nothing && return :empty
            id = String(pick["id"])
            token = next_fencing_token!(store)
            expires = _ts(now_utc + Second(Int(lease_seconds)))
            affected = String[]
            for row in DBInterface.execute(store.db, """
                    UPDATE jobs SET state = 'running', phase = 'materializing_input',
                        attempts = attempts + 1, lease_owner = ?, lease_fencing_token = ?,
                        lease_expires_at = ?, heartbeat_at = ?,
                        started_at = COALESCE(started_at, ?)
                    WHERE id = ? AND state = 'queued' RETURNING id
                """, (String(worker_id), token, expires, _ts(now_utc), _ts(now_utc), id))
                push!(affected, string(row[:id]))
            end
            isempty(affected) && return :retry
            record_audit!(store; action="lease_claim", job_id=id, result_code="running",
                metadata=Dict("worker" => String(worker_id), "fencing_token" => token),
                now_utc=now_utc)
            return ClaimedJob(_fetch_job(store, id), token)
        end
        outcome === :empty && return nothing
        outcome === :retry && continue
        return outcome
    end
    return nothing
end

# ---- submission intents ------------------------------------------------------

"""
    register_submission_intent!(store; ...) -> intent_id

Record, before any storage side effect, that a submission is about to write a
config object. Every config object is therefore always referenced: either by a
job row, or by an intent row that an abort or reconciliation pass resolves.
"""
function register_submission_intent!(store::RuntimeJobStore;
                                     intent_id::AbstractString,
                                     tenant_id::AbstractString,
                                     config_storage_key::AbstractString,
                                     config_sha256::AbstractString,
                                     now_utc::DateTime=now(UTC))
    _exec(store, """
        INSERT INTO submission_intents(id, tenant_id, config_storage_key, config_sha256,
            state, job_id, created_at, updated_at)
        VALUES(?, ?, ?, ?, 'pending', NULL, ?, ?)
    """, (String(intent_id), String(tenant_id), String(config_storage_key),
          String(config_sha256), _ts(now_utc), _ts(now_utc)))
    return String(intent_id)
end

"""Mark a submission intent as committed to the job that now references its object."""
function commit_submission_intent!(store::RuntimeJobStore, intent_id::AbstractString,
                                   job_id::AbstractString; now_utc::DateTime=now(UTC))
    _exec(store,
        "UPDATE submission_intents SET state = 'committed', job_id = ?, updated_at = ? WHERE id = ?",
        (String(job_id), _ts(now_utc), String(intent_id)))
    return nothing
end

"""
    resolve_submission_intent!(store, storage, intent_id; now_utc) -> Symbol

Resolve a pending intent whose submission did not commit (quota/idempotency
rejection or crash recovery). In one transaction the intent's config object is
checked for other references (a job row, or another live intent); if it is
unreferenced the intent is audited as `:reclaimed` and its object deleted from
storage, otherwise the shared object stays and the intent is `:aborted`.
"""
function resolve_submission_intent!(store::RuntimeJobStore, storage, intent_id::AbstractString;
                                    now_utc::DateTime=now(UTC))::Symbol
    # The whole decision, including the storage delete, runs under the store's
    # lock: a concurrent submission can only register its intent (and rewrite
    # the object) strictly before or strictly after this resolution, so a
    # reclaim can never delete an object another live submission relies on.
    return transaction(store) do
        row = _row(store,
            "SELECT config_storage_key, state FROM submission_intents WHERE id = ?",
            (String(intent_id),))
        row === nothing && return :missing
        row["state"] == "pending" || return Symbol(String(row["state"]))
        config_key = String(row["config_storage_key"])
        referenced_jobs = _row(store,
            "SELECT count(*) AS c FROM jobs WHERE config_storage_key = ?", (config_key,))
        referenced_intents = _row(store, """
            SELECT count(*) AS c FROM submission_intents
            WHERE config_storage_key = ? AND id != ? AND state IN ('pending', 'committed')
        """, (config_key, String(intent_id)))
        unreferenced = Int(referenced_jobs["c"]) == 0 && Int(referenced_intents["c"]) == 0
        state = unreferenced ? "reclaimed" : "aborted"
        DBInterface.execute(store.db,
            "UPDATE submission_intents SET state = ?, updated_at = ? WHERE id = ?",
            (state, _ts(now_utc), String(intent_id)))
        record_audit!(store; action="submission_intent_resolved", result_code=state,
            metadata=Dict("intent_id" => String(intent_id), "config_storage_key" => config_key),
            now_utc=now_utc)
        unreferenced && delete_object!(storage, config_key)
        return unreferenced ? :reclaimed : :aborted
    end
end

"""
    reconcile_submission_intents!(store, storage; older_than_seconds, now_utc) -> Vector

Auditable reconciliation pass for intents stranded in `pending` (e.g. a crash
between the storage write and the job commit). Resolves every pending intent
older than the cutoff exactly like an explicit abort.
"""
function reconcile_submission_intents!(store::RuntimeJobStore, storage;
                                       older_than_seconds::Integer=3600,
                                       now_utc::DateTime=now(UTC))
    cutoff = _ts(now_utc - Second(Int(older_than_seconds)))
    rows = _rows(store,
        "SELECT id FROM submission_intents WHERE state = 'pending' AND created_at < ?",
        (cutoff,))
    return [(id=String(row["id"]),
             action=resolve_submission_intent!(store, storage, String(row["id"]); now_utc=now_utc))
            for row in rows]
end

"""
Renew a lease (and optionally advance the internal phase) under fencing guard.

An already-expired lease can never be renewed: expiry is decided against the
control-plane clock passed in `now_utc`, the same time source used by claim
and recovery, so a stale worker cannot resurrect its lease by heartbeating.
"""
function heartbeat!(store::RuntimeJobStore;
                    job_id::AbstractString, worker_id::AbstractString,
                    fencing_token::Integer, lease_seconds::Integer=30,
                    phase::Union{Nothing,AbstractString}=nothing,
                    now_utc::DateTime=now(UTC))::Bool
    phase === nothing || assert_phase(phase)
    expires = _ts(now_utc + Second(Int(lease_seconds)))
    affected = String[]
    Base.lock(store.lock) do
        if phase === nothing
            for row in DBInterface.execute(store.db, """
                    UPDATE jobs SET lease_expires_at = ?, heartbeat_at = ?
                    WHERE id = ? AND lease_owner = ? AND lease_fencing_token = ? AND state = 'running'
                        AND lease_expires_at IS NOT NULL AND lease_expires_at > ?
                    RETURNING id
                """, (expires, _ts(now_utc), String(job_id), String(worker_id), Int(fencing_token), _ts(now_utc)))
                push!(affected, string(row[:id]))
            end
        else
            for row in DBInterface.execute(store.db, """
                    UPDATE jobs SET lease_expires_at = ?, heartbeat_at = ?, phase = ?
                    WHERE id = ? AND lease_owner = ? AND lease_fencing_token = ? AND state = 'running'
                        AND lease_expires_at IS NOT NULL AND lease_expires_at > ?
                    RETURNING id
                """, (expires, _ts(now_utc), String(phase), String(job_id), String(worker_id), Int(fencing_token), _ts(now_utc)))
                push!(affected, string(row[:id]))
            end
        end
    end
    return !isempty(affected)
end

"""
    finalize_job!(store; ...) -> Bool

Commit a terminal state, release the quota reservation and write the terminal
audit event in a single transaction, but only if the caller still holds a
live lease (matching owner and fencing token, not expired against the
control-plane clock). A worker that lost its lease gets `false` and must
publish nothing. A succeeded finalize atomically registers `artifact_prefix`,
which is the only path by which an attempt's output becomes readable.
"""
function finalize_job!(store::RuntimeJobStore;
                       job_id::AbstractString, worker_id::AbstractString,
                       fencing_token::Integer, terminal_state::AbstractString,
                       artifact_keys::Vector{String}=String[],
                       artifact_prefix::Union{Nothing,AbstractString}=nothing,
                       error_code::Union{Nothing,AbstractString}=nothing,
                       error_message::Union{Nothing,AbstractString}=nothing,
                       request_id::Union{Nothing,AbstractString}=nothing,
                       now_utc::DateTime=now(UTC))::Bool
    is_terminal(terminal_state) || throw(RuntimeError("INTERNAL_ERROR",
        "finalize target '$(String(terminal_state))' is not terminal"))
    return transaction(store) do
        current = _fetch_job(store, job_id)
        current === nothing && return false
        (current.state == "running" && current.lease_owner == String(worker_id) &&
            current.lease_fencing_token == Int(fencing_token)) || return false
        (current.lease_expires_at !== nothing && current.lease_expires_at > now_utc) || return false
        # A success commit must register exactly the verified attempt output of
        # the fencing token it presents; anything else is a caller bug.
        if String(terminal_state) == "succeeded"
            expected_prefix = attempt_output_prefix(current.output_prefix, Int(fencing_token))
            (artifact_prefix !== nothing && String(artifact_prefix) == expected_prefix) ||
                throw(RuntimeError("INTERNAL_ERROR",
                    "succeeded finalize requires the attempt artifact prefix '$(expected_prefix)'"))
            required = Set{String}(vcat(
                ["$(expected_prefix)/$(name)" for name in RUNNER_ARTIFACT_NAMES],
                ["$(expected_prefix)/$(ARTIFACT_INDEX_NAME)"]))
            Set{String}(artifact_keys) == required || throw(RuntimeError("INTERNAL_ERROR",
                "succeeded finalize requires the complete verified artifact key set for '$(expected_prefix)'"))
        else
            artifact_prefix === nothing || throw(RuntimeError("INTERNAL_ERROR",
                "only a succeeded finalize may register an artifact prefix"))
        end
        assert_transition("running", terminal_state)
        DBInterface.execute(store.db, """
            UPDATE jobs SET state = ?, phase = NULL, finished_at = ?, lease_owner = NULL,
                lease_expires_at = NULL, artifact_keys = ?, artifact_prefix = ?,
                error_code = ?, error_message = ?
            WHERE id = ?
        """, (
            String(terminal_state), _ts(now_utc), JSON.json(artifact_keys),
            artifact_prefix === nothing ? missing : String(artifact_prefix),
            error_code === nothing ? missing : String(error_code),
            error_message === nothing ? missing : String(error_message),
            String(job_id),
        ))
        DBInterface.execute(store.db, """
            UPDATE quota_reservations SET state = 'released', released_at = ?
            WHERE tenant_id = ? AND job_id = ? AND state = 'active'
        """, (_ts(now_utc), current.tenant_id, String(job_id)))
        record_audit!(store; action="finalize", request_id=request_id,
            tenant_id=current.tenant_id, subject_id=current.subject_id, job_id=job_id,
            result_code=String(terminal_state),
            metadata=Dict("error_code" => error_code === nothing ? nothing : String(error_code)),
            now_utc=now_utc)
        return true
    end
end

# ---- cancellation -----------------------------------------------------------

"""Request cancellation; queued jobs cancel immediately, running jobs cooperatively."""
function request_cancel!(store::RuntimeJobStore, tenant_id::AbstractString, job_id::AbstractString;
                         request_id::Union{Nothing,AbstractString}=nothing,
                         now_utc::DateTime=now(UTC))::RuntimeJob
    return transaction(store) do
        row = _row(store, "SELECT $_JOB_COLUMNS FROM jobs WHERE id = ? AND tenant_id = ?",
            (String(job_id), String(tenant_id)))
        row === nothing && throw(RuntimeError("JOB_NOT_FOUND", "job '$(String(job_id))' was not found"))
        job = _job(row)
        job.state == "cancelled" && return job
        is_terminal(job.state) && throw(RuntimeError("JOB_NOT_CANCELLABLE",
            "job '$(String(job_id))' is already $(job.state)"))
        if job.state == "queued"
            assert_transition("queued", "cancelled")
            DBInterface.execute(store.db, """
                UPDATE jobs SET state = 'cancelled', phase = NULL, finished_at = ?,
                    cancel_requested_at = COALESCE(cancel_requested_at, ?),
                    lease_owner = NULL, lease_expires_at = NULL
                WHERE id = ?
            """, (_ts(now_utc), _ts(now_utc), String(job_id)))
            DBInterface.execute(store.db, """
                UPDATE quota_reservations SET state = 'released', released_at = ?
                WHERE tenant_id = ? AND job_id = ? AND state = 'active'
            """, (_ts(now_utc), String(tenant_id), String(job_id)))
            record_audit!(store; action="cancel", request_id=request_id,
                tenant_id=tenant_id, subject_id=job.subject_id, job_id=job_id,
                result_code="cancelled", now_utc=now_utc)
        else
            DBInterface.execute(store.db, """
                UPDATE jobs SET cancel_requested_at = COALESCE(cancel_requested_at, ?)
                WHERE id = ?
            """, (_ts(now_utc), String(job_id)))
            record_audit!(store; action="cancel_requested", request_id=request_id,
                tenant_id=tenant_id, subject_id=job.subject_id, job_id=job_id,
                result_code="running", now_utc=now_utc)
        end
        return _fetch_job(store, job_id)
    end
end

# ---- lease recovery ---------------------------------------------------------

"""Requeue or fail jobs whose lease has expired; stale workers are fenced out."""
function recover_expired_leases!(store::RuntimeJobStore; now_utc::DateTime=now(UTC))
    recovered = NamedTuple{(:id, :action),Tuple{String,Symbol}}[]
    transaction(store) do
        rows = _rows(store, """
            SELECT $_JOB_COLUMNS FROM jobs
            WHERE state = 'running' AND lease_expires_at IS NOT NULL AND lease_expires_at < ?
        """, (_ts(now_utc),))
        for row in rows
            job = _job(row)
            if job.attempts < job.max_attempts
                DBInterface.execute(store.db, """
                    UPDATE jobs SET state = 'queued', phase = 'waiting_for_worker',
                        lease_owner = NULL, lease_fencing_token = NULL,
                        lease_expires_at = NULL, heartbeat_at = NULL
                    WHERE id = ?
                """, (job.id,))
                record_audit!(store; action="lease_recovered", tenant_id=job.tenant_id,
                    subject_id=job.subject_id, job_id=job.id, result_code="queued",
                    metadata=Dict("attempts" => job.attempts), now_utc=now_utc)
                push!(recovered, (id=job.id, action=:requeued))
            else
                DBInterface.execute(store.db, """
                    UPDATE jobs SET state = 'failed', phase = NULL, finished_at = ?,
                        error_code = 'WORKER_LOST',
                        error_message = 'lease expired and maximum attempts reached',
                        lease_owner = NULL, lease_expires_at = NULL
                    WHERE id = ?
                """, (_ts(now_utc), job.id))
                DBInterface.execute(store.db, """
                    UPDATE quota_reservations SET state = 'released', released_at = ?
                    WHERE tenant_id = ? AND job_id = ? AND state = 'active'
                """, (_ts(now_utc), job.tenant_id, job.id))
                record_audit!(store; action="finalize", tenant_id=job.tenant_id,
                    subject_id=job.subject_id, job_id=job.id, result_code="failed",
                    metadata=Dict("error_code" => "WORKER_LOST"), now_utc=now_utc)
                push!(recovered, (id=job.id, action=:failed))
            end
        end
    end
    return recovered
end

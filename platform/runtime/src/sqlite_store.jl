# RuntimeJobStore: the durable core of the runtime. It owns the SQLite schema,
# migrations, the job state rows, the fencing-token leases, the per-job quota
# reservations and the append-only audit log. All multi-row invariants are
# enforced inside `BEGIN IMMEDIATE` transactions on a single writer connection.

using Dates
using JSON
import SQLite
import DBInterface

const SCHEMA_VERSION = 1
const _FENCING_KEY = "fencing_seq"

"""A durable job row materialized from the store."""
struct RuntimeJob
    id::String
    tenant_id::String
    subject_id::String
    idempotency_key::String
    config_sha256::String
    config_storage_key::String
    output_prefix::String
    resource_profile::String
    concurrency_weight::Int
    release_sha::String
    image_digest::String
    state::String
    phase::Union{Nothing,String}
    attempts::Int
    max_attempts::Int
    lease_owner::Union{Nothing,String}
    lease_fencing_token::Union{Nothing,Int}
    lease_expires_at::Union{Nothing,DateTime}
    heartbeat_at::Union{Nothing,DateTime}
    cancel_requested_at::Union{Nothing,DateTime}
    submitted_at::DateTime
    started_at::Union{Nothing,DateTime}
    finished_at::Union{Nothing,DateTime}
    parent_job_id::Union{Nothing,String}
    artifact_keys::Vector{String}
    artifact_prefix::Union{Nothing,String}
    error_code::Union{Nothing,String}
    error_message::Union{Nothing,String}
end

"""A freshly claimed job together with the fencing token the worker must present."""
struct ClaimedJob
    job::RuntimeJob
    fencing_token::Int
end

mutable struct RuntimeJobStore
    db::SQLite.DB
    path::String
    lock::ReentrantLock
end

function RuntimeJobStore(path::AbstractString=":memory:")
    db = SQLite.DB(String(path))
    if String(path) != ":memory:"
        for _ in DBInterface.execute(db, "PRAGMA journal_mode=WAL;")
        end
    end
    DBInterface.execute(db, "PRAGMA foreign_keys=ON;")
    DBInterface.execute(db, "PRAGMA busy_timeout=5000;")
    store = RuntimeJobStore(db, String(path), ReentrantLock())
    migrate!(store)
    return store
end

close!(store::RuntimeJobStore) = DBInterface.close!(store.db)

# ---- low-level helpers ------------------------------------------------------

function _rows(store::RuntimeJobStore, sql::AbstractString, params=())
    return Base.lock(store.lock) do
        result = Dict{String,Any}[]
        for row in DBInterface.execute(store.db, sql, params)
            entry = Dict{String,Any}()
            for name in propertynames(row)
                entry[String(name)] = getproperty(row, name)
            end
            push!(result, entry)
        end
        result
    end
end

function _row(store::RuntimeJobStore, sql::AbstractString, params=())
    rows = _rows(store, sql, params)
    return isempty(rows) ? nothing : rows[1]
end

_exec(store::RuntimeJobStore, sql::AbstractString, params=()) =
    Base.lock(() -> DBInterface.execute(store.db, sql, params), store.lock)

"""
Run `f` inside a `BEGIN IMMEDIATE` transaction, rolling back on any error.

All writers share one SQLite connection, so the whole transaction is
serialized on the store's reentrant lock: concurrent tasks can never
interleave statements or observe a nested `BEGIN`.
"""
function transaction(f, store::RuntimeJobStore)
    return Base.lock(store.lock) do
        DBInterface.execute(store.db, "BEGIN IMMEDIATE;")
        local value
        try
            value = f()
            DBInterface.execute(store.db, "COMMIT;")
        catch
            try
                DBInterface.execute(store.db, "ROLLBACK;")
            catch
            end
            rethrow()
        end
        value
    end
end

const _ISO_FMT = dateformat"yyyy-mm-ddTHH:MM:SS.sss"
_ts(dt::DateTime) = Dates.format(dt, _ISO_FMT)
_opt_s(x) = (x === missing || x === nothing) ? nothing : String(x)
_opt_i(x) = (x === missing || x === nothing) ? nothing : Int(x)
_opt_dt(x) = (x === missing || x === nothing) ? nothing : DateTime(String(x), _ISO_FMT)
_opt_keys(x) = (x === missing || x === nothing) ? String[] : Vector{String}(JSON.parse(String(x)))

# ---- migrations -------------------------------------------------------------

function migrate!(store::RuntimeJobStore)
    DBInterface.execute(store.db, """
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at TEXT NOT NULL
        );
    """)
    applied = _row(store, "SELECT max(version) AS v FROM schema_migrations")
    current = (applied === nothing || applied["v"] === missing) ? 0 : Int(applied["v"])
    current >= SCHEMA_VERSION && return store
    transaction(store) do
        if current < 1
            _apply_migration_v1(store)
        end
        DBInterface.execute(store.db,
            "INSERT INTO schema_migrations(version, applied_at) VALUES(?, ?)",
            (SCHEMA_VERSION, _ts(now(UTC))))
    end
    return store
end

function _apply_migration_v1(store::RuntimeJobStore)
    DBInterface.execute(store.db, """
        CREATE TABLE runtime_meta (
            key TEXT PRIMARY KEY,
            value INTEGER NOT NULL
        );
    """)
    DBInterface.execute(store.db,
        "INSERT INTO runtime_meta(key, value) VALUES(?, 0)", (_FENCING_KEY,))
    DBInterface.execute(store.db, """
        CREATE TABLE jobs (
            id TEXT PRIMARY KEY,
            tenant_id TEXT NOT NULL,
            subject_id TEXT NOT NULL,
            idempotency_key TEXT NOT NULL,
            config_sha256 TEXT NOT NULL,
            config_storage_key TEXT NOT NULL,
            output_prefix TEXT NOT NULL,
            resource_profile TEXT NOT NULL,
            concurrency_weight INTEGER NOT NULL,
            release_sha TEXT NOT NULL,
            image_digest TEXT NOT NULL,
            state TEXT NOT NULL,
            phase TEXT,
            attempts INTEGER NOT NULL DEFAULT 0,
            max_attempts INTEGER NOT NULL,
            lease_owner TEXT,
            lease_fencing_token INTEGER,
            lease_expires_at TEXT,
            heartbeat_at TEXT,
            cancel_requested_at TEXT,
            submitted_at TEXT NOT NULL,
            started_at TEXT,
            finished_at TEXT,
            parent_job_id TEXT,
            artifact_keys TEXT,
            artifact_prefix TEXT,
            error_code TEXT,
            error_message TEXT,
            UNIQUE(tenant_id, idempotency_key)
        );
    """)
    DBInterface.execute(store.db,
        "CREATE INDEX idx_jobs_tenant_state ON jobs(tenant_id, state);")
    DBInterface.execute(store.db,
        "CREATE INDEX idx_jobs_state_queue ON jobs(state, submitted_at);")
    DBInterface.execute(store.db, """
        CREATE TABLE quota_reservations (
            tenant_id TEXT NOT NULL,
            job_id TEXT NOT NULL,
            artifact_bytes INTEGER NOT NULL,
            concurrency_weight INTEGER NOT NULL,
            state TEXT NOT NULL,
            reserved_at TEXT NOT NULL,
            released_at TEXT,
            PRIMARY KEY(tenant_id, job_id)
        );
    """)
    DBInterface.execute(store.db, """
        CREATE TABLE submission_intents (
            id TEXT PRIMARY KEY,
            tenant_id TEXT NOT NULL,
            config_storage_key TEXT NOT NULL,
            config_sha256 TEXT NOT NULL,
            state TEXT NOT NULL,
            job_id TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
    """)
    DBInterface.execute(store.db,
        "CREATE INDEX idx_submission_intents_state ON submission_intents(state, created_at);")
    DBInterface.execute(store.db, """
        CREATE TABLE audit_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            at TEXT NOT NULL,
            request_id TEXT,
            tenant_id TEXT,
            subject_id TEXT,
            action TEXT NOT NULL,
            job_id TEXT,
            result_code TEXT,
            metadata TEXT
        );
    """)
    return nothing
end

# ---- row mapping ------------------------------------------------------------

function _job(row::Dict{String,Any})
    return RuntimeJob(
        String(row["id"]),
        String(row["tenant_id"]),
        String(row["subject_id"]),
        String(row["idempotency_key"]),
        String(row["config_sha256"]),
        String(row["config_storage_key"]),
        String(row["output_prefix"]),
        String(row["resource_profile"]),
        Int(row["concurrency_weight"]),
        String(row["release_sha"]),
        String(row["image_digest"]),
        String(row["state"]),
        _opt_s(row["phase"]),
        Int(row["attempts"]),
        Int(row["max_attempts"]),
        _opt_s(row["lease_owner"]),
        _opt_i(row["lease_fencing_token"]),
        _opt_dt(row["lease_expires_at"]),
        _opt_dt(row["heartbeat_at"]),
        _opt_dt(row["cancel_requested_at"]),
        DateTime(String(row["submitted_at"]), _ISO_FMT),
        _opt_dt(row["started_at"]),
        _opt_dt(row["finished_at"]),
        _opt_s(row["parent_job_id"]),
        _opt_keys(row["artifact_keys"]),
        _opt_s(row["artifact_prefix"]),
        _opt_s(row["error_code"]),
        _opt_s(row["error_message"]),
    )
end

const _JOB_COLUMNS = "id, tenant_id, subject_id, idempotency_key, config_sha256, " *
    "config_storage_key, output_prefix, resource_profile, concurrency_weight, " *
    "release_sha, image_digest, state, phase, attempts, max_attempts, lease_owner, " *
    "lease_fencing_token, lease_expires_at, heartbeat_at, cancel_requested_at, " *
    "submitted_at, started_at, finished_at, parent_job_id, artifact_keys, " *
    "artifact_prefix, error_code, error_message"

function _fetch_job(store::RuntimeJobStore, id::AbstractString)
    row = _row(store, "SELECT $_JOB_COLUMNS FROM jobs WHERE id = ?", (String(id),))
    return row === nothing ? nothing : _job(row)
end

# ---- audit ------------------------------------------------------------------

function record_audit!(store::RuntimeJobStore; action::AbstractString,
                       request_id=nothing, tenant_id=nothing, subject_id=nothing,
                       job_id=nothing, result_code=nothing, metadata=nothing,
                       now_utc::DateTime=now(UTC))
    _exec(store, """
        INSERT INTO audit_events(at, request_id, tenant_id, subject_id, action, job_id, result_code, metadata)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?)
    """, (
        _ts(now_utc),
        request_id === nothing ? missing : String(request_id),
        tenant_id === nothing ? missing : String(tenant_id),
        subject_id === nothing ? missing : String(subject_id),
        String(action),
        job_id === nothing ? missing : String(job_id),
        result_code === nothing ? missing : String(result_code),
        metadata === nothing ? missing : JSON.json(metadata),
    ))
    return nothing
end

function audit_events(store::RuntimeJobStore; job_id=nothing)
    if job_id === nothing
        return _rows(store, "SELECT * FROM audit_events ORDER BY id")
    end
    return _rows(store, "SELECT * FROM audit_events WHERE job_id = ? ORDER BY id", (String(job_id),))
end

# ---- fencing ----------------------------------------------------------------

"""Allocate the next strictly-increasing fencing token (call inside a transaction)."""
function next_fencing_token!(store::RuntimeJobStore)::Int
    token = nothing
    for row in DBInterface.execute(store.db,
            "UPDATE runtime_meta SET value = value + 1 WHERE key = ? RETURNING value",
            (_FENCING_KEY,))
        token = Int(row[:value])
    end
    token === nothing && throw(RuntimeError("INTERNAL_ERROR", "fencing counter row is missing"))
    return token
end

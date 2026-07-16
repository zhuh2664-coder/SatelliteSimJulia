"""
    SatelliteSimPlatformRuntime

Pure-Julia Runtime Application Service for the SatelliteSim platform (Phase 2A).

This package owns the transport-neutral runtime core: the durable
`RuntimeJobStore` (SQLite), the job state machine, fencing-token leases,
idempotency, quota, an append-only audit log, admission control, the stable
public error taxonomy, the `AbstractExecutionBackend` contract
(`start`/`status`/`wait_result`/`cancel`) with a deterministic in-process test
backend, and the ten runtime operations. It deliberately contains no transport,
no network, no credentials and no real runner; those arrive in later PRs.
"""
module SatelliteSimPlatformRuntime

using Dates
using JSON
using SHA
using UUIDs
import SQLite
import DBInterface

include("errors.jl")
include("state.jl")
include("admission.jl")
include("sqlite_store.jl")
include("job_ops.jl")
include("execution.jl")
include("service.jl")
include("worker.jl")

# error taxonomy / envelope
export RuntimeError, RUNTIME_ERROR_CODES, RETRYABLE_ERROR_CODES,
    success_envelope, error_envelope

# state machine
export PUBLIC_STATES, TERMINAL_STATES, INTERNAL_PHASES,
    is_public_state, is_terminal, can_transition, assert_transition, assert_phase

# admission / profiles
export ResourceProfile, RESOURCE_PROFILES, DEFAULT_RESOURCE_PROFILE,
    resource_profile, RuntimeResources, to_resources, enforce_admission,
    admission_estimate_data, AdmissionEstimate

# durable store
export RuntimeJobStore, RuntimeJob, ClaimedJob, SCHEMA_VERSION, close!,
    migrate!, transaction, record_audit!, audit_events, next_fencing_token!

# job lifecycle operations
export create_job!, precheck_quota, get_job, list_jobs, claim_next_job!, heartbeat!,
    finalize_job!, request_cancel!, recover_expired_leases!,
    register_submission_intent!, commit_submission_intent!, resolve_submission_intent!,
    reconcile_submission_intents!, reconcile_submissions!

# execution backend
export AbstractExecutionBackend, ExecutionSpec, ExecutionStatus, ExecutionResult,
    DeterministicTestBackend, backend_start, backend_status, backend_wait_result,
    backend_cancel!, backend_probe, write_runner_artifacts, verify_artifact_contract,
    attempt_output_prefix, RUNNER_ARTIFACT_NAMES, ARTIFACT_INDEX_NAME

# application service (the ten runtime operations) + worker driver
export RuntimeApplicationService, runtime_health, runtime_capabilities,
    validate_experiment, submit_experiment, get_job_view, list_jobs_view,
    cancel_job, get_artifacts, read_result, reproduce_job, process_next_job!

end # module

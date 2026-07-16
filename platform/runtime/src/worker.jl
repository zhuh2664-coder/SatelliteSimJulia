# Single-step worker driver. In Phase 2A this runs in-process against the
# deterministic backend so the full lease -> execute -> verify -> finalize path
# is exercised deterministically. The same control flow is what a real GCP
# worker (PR2) will follow: it only ever advances a job it currently leases,
# it stops the moment it loses its lease (fencing), and it publishes artifacts
# to storage before committing the terminal state (recoverable commit).

using Dates
using JSON
using SatelliteSimPlatformStorage: get_json, upload_directory!

"""
    process_next_job!(service; ...) -> NamedTuple

Claim and fully drive the oldest queued job. Returns a status tuple; possible
statuses are `:empty`, `:succeeded`, `:failed`, `:cancelled` and `:lease_lost`.
A `:lease_lost` result means the worker detected it no longer held the lease
and therefore committed nothing.
"""
function process_next_job!(service::RuntimeApplicationService;
                           worker_id::AbstractString="worker-local",
                           lease_seconds::Integer=30,
                           poll_interval::Real=0.0,
                           max_polls::Integer=10_000,
                           on_running::Union{Nothing,Function}=nothing)
    store = service.store
    claim = claim_next_job!(store; worker_id=worker_id, lease_seconds=lease_seconds,
        now_utc=service.clock())
    claim === nothing && return (status=:empty, job_id=nothing)
    job = claim.job
    token = claim.fencing_token
    started = service.clock()
    workdir = mktempdir()
    claim_handle = Ref{Any}(nothing)

    # Losing the lease (failed heartbeat or fenced-out finalize) must stop the
    # backend execution immediately: a fenced worker may not keep running.
    lease_lost() = begin
        claim_handle[] === nothing || backend_cancel!(service.backend, claim_handle[])
        (status=:lease_lost, job_id=job.id)
    end
    hb(phase) = heartbeat!(store; job_id=job.id, worker_id=worker_id, fencing_token=token,
        lease_seconds=lease_seconds, phase=phase, now_utc=service.clock())
    fail(code, message) = begin
        ok = finalize_job!(store; job_id=job.id, worker_id=worker_id, fencing_token=token,
            terminal_state="failed", error_code=code, error_message=message,
            now_utc=service.clock())
        ok ? (status=:failed, job_id=job.id, code=code) : lease_lost()
    end
    cancel_now() = begin
        backend_cancel!(service.backend, claim_handle[])
        ok = finalize_job!(store; job_id=job.id, worker_id=worker_id, fencing_token=token,
            terminal_state="cancelled", now_utc=service.clock())
        ok ? (status=:cancelled, job_id=job.id) : lease_lost()
    end

    try
        normalized = get_json(service.storage, job.config_storage_key)
        input_dir = joinpath(workdir, "input")
        mkpath(input_dir)
        open(joinpath(input_dir, "config.json"), "w") do io
            write(io, JSON.json(normalized))
        end
        hb("materializing_input") || return lease_lost()
        profile = resource_profile(job.resource_profile)
        output_dir = joinpath(workdir, "output")
        mkpath(output_dir)
        spec = ExecutionSpec(job.id, job.tenant_id, job.release_sha, job.image_digest,
            Dict{String,Any}(normalized), input_dir, output_dir,
            profile.cpu_millicores, profile.memory_mib, profile.timeout_seconds)
        hb("starting_runner") || return lease_lost()
        claim_handle[] = backend_start(service.backend, spec)
        hb("simulating") || return lease_lost()
        on_running === nothing || on_running(job)

        polls = 0
        while true
            polls += 1
            polls > max_polls && return fail("EXECUTION_TIMEOUT", "exceeded poll budget")
            current = get_job(store, job.tenant_id, job.id)
            if current !== nothing && current.cancel_requested_at !== nothing
                return cancel_now()
            end
            status = backend_status(service.backend, claim_handle[])
            if status.state == :succeeded
                break
            elseif status.state == :failed
                return fail("EXECUTION_FAILED", something(status.message, "execution failed"))
            elseif status.state == :cancelled
                return cancel_now()
            end
            if (service.clock() - started) > Millisecond(profile.timeout_seconds * 1000)
                backend_cancel!(service.backend, claim_handle[])
                return fail("EXECUTION_TIMEOUT", "execution exceeded timeout of $(profile.timeout_seconds)s")
            end
            hb("simulating") || return lease_lost()
            poll_interval > 0 && sleep(poll_interval)
        end

        hb("uploading_artifacts") || return lease_lost()
        result = backend_wait_result(service.backend, claim_handle[])
        result.exit_status == :succeeded ||
            return fail("EXECUTION_FAILED", something(result.error_message, "runner did not succeed"))
        # Recoverable commit: each attempt publishes into its own fencing-token
        # prefix, never the job's canonical prefix, and the prefix only becomes
        # readable when finalize registers it atomically under the fencing guard.
        attempt_prefix = attempt_output_prefix(job.output_prefix, token)
        upload_directory!(service.storage, attempt_prefix, result.artifact_dir)
        artifact_keys = verify_artifact_contract(service.storage, attempt_prefix)
        ok = finalize_job!(store; job_id=job.id, worker_id=worker_id, fencing_token=token,
            terminal_state="succeeded", artifact_keys=artifact_keys,
            artifact_prefix=attempt_prefix, now_utc=service.clock())
        return ok ? (status=:succeeded, job_id=job.id, artifact_keys=artifact_keys) :
            lease_lost()
    catch error
        error isa RuntimeError && return fail(error.code, error.message)
        return fail("EXECUTION_FAILED", "internal execution error")
    finally
        rm(workdir; force=true, recursive=true)
    end
end

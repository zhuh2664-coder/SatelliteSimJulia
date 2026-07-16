# Lease and fencing-token race evidence. A worker that has lost its lease must
# be unable to renew it, update job state, or publish artifacts; the fencing
# token is strictly monotonic and a fresh claim always supersedes a stale one.

using Dates

_attempt_keys(prefix) = vcat(
    ["$(prefix)/$(name)" for name in SatelliteSimPlatformRuntime.RUNNER_ARTIFACT_NAMES],
    ["$(prefix)/$(SatelliteSimPlatformRuntime.ARTIFACT_INDEX_NAME)"])

function _seed_queued_job(store; job_id, key, max_attempts=2)
    create_job!(store; job_id=job_id, tenant_id="tenant-a", subject_id="alice",
        idempotency_key=key, config_sha256=repeat("a", 64),
        config_storage_key="k-$job_id", output_prefix="p-$job_id",
        resource_profile="small", concurrency_weight=1, artifact_bytes=1024,
        release_sha="rel", image_digest="d", max_attempts=max_attempts)
end

@testset "lease_race" begin
    @testset "fencing tokens are strictly monotonic" begin
        store = RuntimeJobStore()
        tokens = Int[]
        for _ in 1:5
            transaction(store) do
                push!(tokens, next_fencing_token!(store))
            end
        end
        @test tokens == [1, 2, 3, 4, 5]
    end

    @testset "a stale worker is fenced out after lease recovery" begin
        dir = mktempdir()
        path = joinpath(dir, "runtime.db")
        store = RuntimeJobStore(path)
        _seed_queued_job(store; job_id="job-1", key="race-1")
        t0 = DateTime(2026, 1, 1, 0, 0, 0)

        claim_a = claim_next_job!(store; worker_id="A", lease_seconds=30, now_utc=t0)
        @test claim_a.fencing_token == 1
        @test claim_a.job.lease_owner == "A"

        # A's lease expires; recovery requeues the job (attempt 1 < max attempts 2)
        recovered = recover_expired_leases!(store; now_utc=t0 + Second(120))
        @test recovered == [(id="job-1", action=:requeued)]

        # A fresh worker B claims and receives a strictly higher fencing token
        claim_b = claim_next_job!(store; worker_id="B", lease_seconds=30, now_utc=t0 + Second(121))
        @test claim_b.fencing_token == 2
        @test claim_b.job.lease_owner == "B"

        # The stale worker A (old token) can neither renew nor commit
        @test heartbeat!(store; job_id="job-1", worker_id="A",
            fencing_token=claim_a.fencing_token, now_utc=t0 + Second(122)) == false
        @test finalize_job!(store; job_id="job-1", worker_id="A",
            fencing_token=claim_a.fencing_token, terminal_state="succeeded") == false

        # The job is still owned by B and unchanged by the stale worker
        current = get_job(store, "tenant-a", "job-1")
        @test current.state == "running"
        @test current.lease_owner == "B"
        @test current.lease_fencing_token == 2

        # Only the current lease holder B can renew and finalize
        @test heartbeat!(store; job_id="job-1", worker_id="B",
            fencing_token=claim_b.fencing_token, now_utc=t0 + Second(123)) == true
        prefix_b = attempt_output_prefix(claim_b.job.output_prefix, claim_b.fencing_token)
        @test finalize_job!(store; job_id="job-1", worker_id="B",
            fencing_token=claim_b.fencing_token, terminal_state="succeeded",
            artifact_keys=_attempt_keys(prefix_b), artifact_prefix=prefix_b,
            now_utc=t0 + Second(124)) == true
        @test get_job(store, "tenant-a", "job-1").state == "succeeded"
        SatelliteSimPlatformRuntime.close!(store)
    end

    @testset "an expired lease can neither heartbeat nor finalize" begin
        store = RuntimeJobStore()
        _seed_queued_job(store; job_id="job-exp", key="race-exp")
        t0 = DateTime(2026, 3, 1, 0, 0, 0)
        claim = claim_next_job!(store; worker_id="A", lease_seconds=30, now_utc=t0)

        # within the lease both operations succeed
        @test heartbeat!(store; job_id="job-exp", worker_id="A",
            fencing_token=claim.fencing_token, now_utc=t0 + Second(10)) == true

        # past expiry (renewed to t0+40) the same owner and token are rejected
        @test heartbeat!(store; job_id="job-exp", worker_id="A",
            fencing_token=claim.fencing_token, now_utc=t0 + Second(120)) == false
        @test finalize_job!(store; job_id="job-exp", worker_id="A",
            fencing_token=claim.fencing_token, terminal_state="succeeded",
            now_utc=t0 + Second(120)) == false
        job = get_job(store, "tenant-a", "job-exp")
        @test job.state == "running"  # untouched until recovery runs
        @test recover_expired_leases!(store; now_utc=t0 + Second(121)) ==
            [(id="job-exp", action=:requeued)]
    end

    @testset "a stale attempt can never become the readable artifact set" begin
        storage_root = mktempdir()
        service = make_service(; storage_root=storage_root)
        store = service.store
        t0 = DateTime(2026, 4, 1, 0, 0, 0)

        submitted = submit_experiment(service, submitter(), raw_config(); idempotency_key="stale-attempt")
        job_id = submitted["job_id"]

        # worker A claims (token 1) and uploads into its attempt prefix, but
        # its lease expires before it can finalize
        claim_a = claim_next_job!(store; worker_id="A", lease_seconds=30, now_utc=t0)
        job_a = claim_a.job
        stale_prefix = attempt_output_prefix(job_a.output_prefix, claim_a.fencing_token)
        stale_dir = mktempdir()
        stale_spec = ExecutionSpec(job_a.id, job_a.tenant_id, "stale-rel", "sha256:stale",
            Dict{String,Any}("name" => "stale"), mktempdir(), stale_dir, 1, 1, 60)
        write_runner_artifacts(stale_spec)
        SatelliteSimPlatformRuntime.upload_directory!(service.storage, stale_prefix, stale_dir)

        recover_expired_leases!(store; now_utc=t0 + Second(120))

        # stale A cannot register its attempt prefix
        @test finalize_job!(store; job_id=job_a.id, worker_id="A",
            fencing_token=claim_a.fencing_token, terminal_state="succeeded",
            artifact_keys=["$(stale_prefix)/result.json"], artifact_prefix=stale_prefix,
            now_utc=t0 + Second(121)) == false

        # worker B (fresh token) drives the job to success through the worker path
        outcome = process_next_job!(service; worker_id="B")
        @test outcome.status == :succeeded

        job = get_job(store, "tenant-a", job_id)
        @test job.artifact_prefix !== nothing
        @test job.artifact_prefix != stale_prefix
        @test all(k -> startswith(k, job.artifact_prefix), job.artifact_keys)

        # the public read surface only ever exposes the registered prefix
        artifacts = get_artifacts(service, submitter(), job_id)
        @test artifacts["output_prefix"] == job.artifact_prefix
        @test all(k -> !occursin(stale_prefix, k), artifacts["artifact_keys"])
        result = read_result(service, submitter(), job_id)
        @test result["result"]["deterministic"] == true
    end

    @testset "exhausted attempts fail as WORKER_LOST" begin
        store = RuntimeJobStore()
        _seed_queued_job(store; job_id="job-2", key="race-2", max_attempts=1)
        t0 = DateTime(2026, 2, 1, 0, 0, 0)
        claim = claim_next_job!(store; worker_id="A", lease_seconds=30, now_utc=t0)
        @test claim.job.attempts == 1
        recovered = recover_expired_leases!(store; now_utc=t0 + Second(120))
        @test recovered == [(id="job-2", action=:failed)]
        job = get_job(store, "tenant-a", "job-2")
        @test job.state == "failed"
        @test job.error_code == "WORKER_LOST"
        reservation = SatelliteSimPlatformRuntime._row(store,
            "SELECT state FROM quota_reservations WHERE job_id = ?", ("job-2",))
        @test reservation["state"] == "released"
    end

    @testset "a single claim wins for one queued job" begin
        store = RuntimeJobStore()
        _seed_queued_job(store; job_id="job-3", key="race-3")
        first = claim_next_job!(store; worker_id="A")
        @test first !== nothing
        second = claim_next_job!(store; worker_id="B")
        @test second === nothing  # no queued job remains to double-claim
    end
end

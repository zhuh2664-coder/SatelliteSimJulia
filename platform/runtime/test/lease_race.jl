# Lease and fencing-token race evidence. A worker that has lost its lease must
# be unable to renew it, update job state, or publish artifacts; the fencing
# token is strictly monotonic and a fresh claim always supersedes a stale one.

using Dates

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
        @test finalize_job!(store; job_id="job-1", worker_id="B",
            fencing_token=claim_b.fencing_token, terminal_state="succeeded") == true
        @test get_job(store, "tenant-a", "job-1").state == "succeeded"
        SatelliteSimPlatformRuntime.close!(store)
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

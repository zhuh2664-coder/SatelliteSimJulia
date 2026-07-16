# SQLite persistence: durability across reopen, migrations, idempotency,
# quota accounting and the single-transaction terminal + release + audit.

@testset "persistence" begin
    @testset "schema migration is versioned and idempotent" begin
        dir = mktempdir()
        path = joinpath(dir, "runtime.db")
        store = RuntimeJobStore(path)
        version = SatelliteSimPlatformRuntime._row(store, "SELECT max(version) AS v FROM schema_migrations")
        @test Int(version["v"]) == SCHEMA_VERSION
        SatelliteSimPlatformRuntime.close!(store)
        # reopening runs migrate! again but must not reapply or duplicate rows
        store2 = RuntimeJobStore(path)
        count = SatelliteSimPlatformRuntime._row(store2, "SELECT count(*) AS c FROM schema_migrations")
        @test Int(count["c"]) == 1
        SatelliteSimPlatformRuntime.close!(store2)
    end

    @testset "jobs survive a store reopen" begin
        dir = mktempdir()
        path = joinpath(dir, "runtime.db")
        store = RuntimeJobStore(path)
        job, created = create_job!(store; job_id="job-persist", tenant_id="tenant-a",
            subject_id="alice", idempotency_key="persist-1", config_sha256=repeat("a", 64),
            config_storage_key="tenants/tenant-a/jobs/job-persist/config.normalized.json",
            output_prefix="tenants/tenant-a/jobs/job-persist/artifacts",
            resource_profile="small", concurrency_weight=1, artifact_bytes=1024,
            release_sha="rel", image_digest="sha256:x")
        @test created == true
        SatelliteSimPlatformRuntime.close!(store)

        reopened = RuntimeJobStore(path)
        restored = get_job(reopened, "tenant-a", "job-persist")
        @test restored !== nothing
        @test restored.state == "queued"
        @test restored.idempotency_key == "persist-1"
        SatelliteSimPlatformRuntime.close!(reopened)
    end

    @testset "idempotency unique constraint at the store" begin
        store = RuntimeJobStore()
        args = (; tenant_id="tenant-a", subject_id="alice", idempotency_key="dup",
            config_sha256=repeat("b", 64),
            config_storage_key="k", output_prefix="p", resource_profile="small",
            concurrency_weight=1, artifact_bytes=1024, release_sha="rel", image_digest="d")
        job1, c1 = create_job!(store; job_id="job-a", args...)
        @test c1 == true
        job2, c2 = create_job!(store; job_id="job-b", args...)
        @test c2 == false
        @test job2.id == job1.id  # same normalized config returns the original

        err = try
            create_job!(store; job_id="job-c", tenant_id="tenant-a", subject_id="alice",
                idempotency_key="dup", config_sha256=repeat("c", 64), config_storage_key="k",
                output_prefix="p", resource_profile="small", concurrency_weight=1,
                artifact_bytes=1024, release_sha="rel", image_digest="d")
            nothing
        catch e
            e
        end
        @test err isa RuntimeError && err.code == "IDEMPOTENCY_CONFLICT"
    end

    @testset "tenant concurrency cap" begin
        store = RuntimeJobStore()
        mk(id, key) = create_job!(store; job_id=id, tenant_id="tenant-a", subject_id="alice",
            idempotency_key=key, config_sha256=repeat("1", 64), config_storage_key="k$id",
            output_prefix="p$id", resource_profile="small", concurrency_weight=1,
            artifact_bytes=1024, release_sha="rel", image_digest="d")
        mk("job-1", "k1")
        mk("job-2", "k2")
        err = try
            mk("job-3", "k3")
            nothing
        catch e
            e
        end
        @test err isa RuntimeError && err.code == "QUOTA_EXCEEDED"
    end

    @testset "concurrent submit/claim/cancel never nest transactions" begin
        store = RuntimeJobStore()
        errors = Base.Channel{Any}(64)
        tasks = Task[]
        for worker in 1:8
            task = Threads.@spawn begin
                try
                    for round in 1:5
                        id = "job-c$(worker)-$(round)"
                        try
                            create_job!(store; job_id=id, tenant_id="tenant-w$(worker)",
                                subject_id="alice", idempotency_key="key-$(worker)-$(round)",
                                config_sha256=repeat("f", 64), config_storage_key="k$id",
                                output_prefix="p$id", resource_profile="small",
                                concurrency_weight=1, artifact_bytes=1024,
                                release_sha="rel", image_digest="d")
                        catch e
                            e isa RuntimeError && e.code == "QUOTA_EXCEEDED" || rethrow()
                        end
                        claim = claim_next_job!(store; worker_id="w$(worker)")
                        if claim !== nothing
                            finalize_job!(store; job_id=claim.job.id, worker_id="w$(worker)",
                                fencing_token=claim.fencing_token, terminal_state="succeeded")
                        end
                        try
                            request_cancel!(store, "tenant-w$(worker)", "job-c$(worker)-$(round)")
                        catch e
                            e isa RuntimeError || rethrow()
                        end
                    end
                catch e
                    put!(errors, e)
                end
            end
            push!(tasks, task)
        end
        foreach(wait, tasks)
        close(errors)
        collected = collect(errors)
        # no SQLite "cannot start a transaction within a transaction" or any
        # other interleaving error may escape the serialized store
        @test collected == []
        # every reservation row still corresponds to exactly one job row
        orphan = SatelliteSimPlatformRuntime._row(store, """
            SELECT count(*) AS c FROM quota_reservations q
            WHERE NOT EXISTS (SELECT 1 FROM jobs j WHERE j.id = q.job_id)
        """)
        @test Int(orphan["c"]) == 0
        # no non-terminal job may hold a released reservation or vice versa
        inconsistent = SatelliteSimPlatformRuntime._row(store, """
            SELECT count(*) AS c FROM jobs j JOIN quota_reservations q ON q.job_id = j.id
            WHERE (j.state IN ('queued','running') AND q.state != 'active')
               OR (j.state IN ('succeeded','failed','cancelled') AND q.state != 'released')
        """)
        @test Int(inconsistent["c"]) == 0
    end

    @testset "rejected submissions leak neither quota nor storage objects" begin
        service = make_service()
        # fill the tenant cap (2 x small)
        submit_experiment(service, submitter(), raw_config(); idempotency_key="leak-1")
        submit_experiment(service, submitter(), raw_config(); idempotency_key="leak-2")
        objects_before = length(SatelliteSimPlatformRuntime.list_objects(service.storage; prefix=""))

        err = try
            submit_experiment(service, submitter(), raw_config(); idempotency_key="leak-3")
            nothing
        catch e
            e
        end
        @test err isa RuntimeError && err.code == "QUOTA_EXCEEDED"

        conflicting = raw_config()
        conflicting["alpha"] = 0.9
        err2 = try
            submit_experiment(service, submitter(), conflicting; idempotency_key="leak-1")
            nothing
        catch e
            e
        end
        @test err2 isa RuntimeError && err2.code == "IDEMPOTENCY_CONFLICT"

        # neither rejection created a job row, a reservation or a storage object
        @test length(SatelliteSimPlatformRuntime.list_objects(service.storage; prefix="")) == objects_before
        rows = SatelliteSimPlatformRuntime._row(service.store, "SELECT count(*) AS c FROM jobs")
        @test Int(rows["c"]) == 2
        active = SatelliteSimPlatformRuntime._row(service.store,
            "SELECT count(*) AS c FROM quota_reservations WHERE state = 'active'")
        @test Int(active["c"]) == 2
        # both jobs share one content-addressed config object
        @test objects_before == 1
    end

    @testset "terminal state, quota release and audit are one transaction" begin
        store = RuntimeJobStore()
        create_job!(store; job_id="job-final", tenant_id="tenant-a", subject_id="alice",
            idempotency_key="final", config_sha256=repeat("2", 64), config_storage_key="k",
            output_prefix="p", resource_profile="small", concurrency_weight=1,
            artifact_bytes=1024, release_sha="rel", image_digest="d")
        claim = claim_next_job!(store; worker_id="w1")
        @test claim.job.id == "job-final"
        ok = finalize_job!(store; job_id="job-final", worker_id="w1",
            fencing_token=claim.fencing_token, terminal_state="succeeded",
            artifact_keys=["p/result.json"])
        @test ok == true

        job = get_job(store, "tenant-a", "job-final")
        @test job.state == "succeeded"
        @test job.lease_owner === nothing
        reservation = SatelliteSimPlatformRuntime._row(store,
            "SELECT state FROM quota_reservations WHERE job_id = ?", ("job-final",))
        @test reservation["state"] == "released"
        events = audit_events(store; job_id="job-final")
        actions = Set(String(e["action"]) for e in events)
        @test "submit_experiment" in actions
        @test "lease_claim" in actions
        @test "finalize" in actions
    end
end

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
                                fencing_token=claim.fencing_token, terminal_state="failed",
                                error_code="EXECUTION_FAILED")
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

    @testset "concurrent submissions leave no orphaned config objects" begin
        service = make_service()
        # one slot is taken up-front so exactly one of the two racing
        # submissions below can win the remaining capacity
        submit_experiment(service, submitter(), raw_config(); idempotency_key="race-base")

        variant(a) = (c = raw_config(); c["alpha"] = a; c)
        results = Vector{Any}(undef, 2)
        submit_one(i) = try
            results[i] = submit_experiment(service, submitter(), variant(0.1 * i);
                idempotency_key="race-$(i)")
        catch e
            results[i] = e
        end
        tasks = [Threads.@spawn(submit_one($i)) for i in 1:2]
        foreach(wait, tasks)

        accepted = count(r -> r isa Dict, results)
        rejected = [r for r in results if !(r isa Dict)]
        @test all(e -> e isa RuntimeError && e.code == "QUOTA_EXCEEDED", rejected)
        @test accepted + length(rejected) == 2

        # every stored config object is referenced by a job row; the rejected
        # submission's distinct config was reclaimed through its intent
        referenced = Set(String(row["config_storage_key"]) for row in
            SatelliteSimPlatformRuntime._rows(service.store, "SELECT config_storage_key FROM jobs"))
        stored = Set(o.key for o in
            SatelliteSimPlatformRuntime.list_objects(service.storage; prefix="tenants/tenant-a/configs"))
        @test stored == referenced

        # no intent is left pending, and any reclaim was audited
        pending = SatelliteSimPlatformRuntime._row(service.store,
            "SELECT count(*) AS c FROM submission_intents WHERE state = 'pending'")
        @test Int(pending["c"]) == 0
        if accepted == 1
            reclaimed = SatelliteSimPlatformRuntime._row(service.store,
                "SELECT count(*) AS c FROM submission_intents WHERE state = 'reclaimed'")
            @test Int(reclaimed["c"]) == 1
            events = audit_events(service.store)
            @test any(e -> String(e["action"]) == "submission_intent_resolved", events)
        end
    end

    @testset "stranded pending intents are reconciled with an audit trail" begin
        service = make_service()
        submitted = submit_experiment(service, submitter(), raw_config(); idempotency_key="recon-1")
        # simulate a crash: a pending intent whose submission never committed,
        # plus its orphan-candidate object with a distinct config hash
        orphan_key = "tenants/tenant-a/configs/$(repeat("9", 64)).json"
        SatelliteSimPlatformRuntime.put_json!(service.storage, orphan_key, Dict("x" => 1))
        register_submission_intent!(service.store; intent_id="intent-stranded",
            tenant_id="tenant-a", config_storage_key=orphan_key,
            config_sha256=repeat("9", 64), now_utc=service.clock() - Hour(2))

        outcome = reconcile_submissions!(service; older_than_seconds=3600)
        @test outcome == [(id="intent-stranded", action=:reclaimed)]
        @test !SatelliteSimPlatformRuntime.has_object(service.storage, orphan_key)
        # the committed submission's object is untouched
        job = get_job(service.store, "tenant-a", submitted["job_id"])
        @test SatelliteSimPlatformRuntime.has_object(service.storage, job.config_storage_key)
    end

    @testset "a succeeded finalize without a valid artifact registration is rejected" begin
        store = RuntimeJobStore()
        create_job!(store; job_id="job-strict", tenant_id="tenant-a", subject_id="alice",
            idempotency_key="strict", config_sha256=repeat("3", 64), config_storage_key="k",
            output_prefix="p", resource_profile="small", concurrency_weight=1,
            artifact_bytes=1024, release_sha="rel", image_digest="d")
        claim = claim_next_job!(store; worker_id="w1")
        prefix = attempt_output_prefix("p", claim.fencing_token)
        keys = vcat(
            ["$(prefix)/$(name)" for name in SatelliteSimPlatformRuntime.RUNNER_ARTIFACT_NAMES],
            ["$(prefix)/$(SatelliteSimPlatformRuntime.ARTIFACT_INDEX_NAME)"])

        expect_internal(f) = begin
            err = try; f(); nothing; catch e; e; end
            @test err isa RuntimeError && err.code == "INTERNAL_ERROR"
        end
        # missing artifact_prefix
        expect_internal(() -> finalize_job!(store; job_id="job-strict", worker_id="w1",
            fencing_token=claim.fencing_token, terminal_state="succeeded", artifact_keys=keys))
        # prefix of a different fencing token
        expect_internal(() -> finalize_job!(store; job_id="job-strict", worker_id="w1",
            fencing_token=claim.fencing_token, terminal_state="succeeded", artifact_keys=keys,
            artifact_prefix=attempt_output_prefix("p", claim.fencing_token + 1)))
        # incomplete artifact key set
        expect_internal(() -> finalize_job!(store; job_id="job-strict", worker_id="w1",
            fencing_token=claim.fencing_token, terminal_state="succeeded",
            artifact_keys=["$(prefix)/result.json"], artifact_prefix=prefix))
        # a non-succeeded finalize must not register a prefix
        expect_internal(() -> finalize_job!(store; job_id="job-strict", worker_id="w1",
            fencing_token=claim.fencing_token, terminal_state="failed",
            error_code="EXECUTION_FAILED", artifact_prefix=prefix))

        # the job is still running and untouched after every rejection
        job = get_job(store, "tenant-a", "job-strict")
        @test job.state == "running"
        @test job.artifact_prefix === nothing

        # the complete, token-matched registration still succeeds
        @test finalize_job!(store; job_id="job-strict", worker_id="w1",
            fencing_token=claim.fencing_token, terminal_state="succeeded",
            artifact_keys=keys, artifact_prefix=prefix) == true
        @test get_job(store, "tenant-a", "job-strict").state == "succeeded"
    end

    @testset "terminal state, quota release and audit are one transaction" begin
        store = RuntimeJobStore()
        create_job!(store; job_id="job-final", tenant_id="tenant-a", subject_id="alice",
            idempotency_key="final", config_sha256=repeat("2", 64), config_storage_key="k",
            output_prefix="p", resource_profile="small", concurrency_weight=1,
            artifact_bytes=1024, release_sha="rel", image_digest="d")
        claim = claim_next_job!(store; worker_id="w1")
        @test claim.job.id == "job-final"
        prefix = attempt_output_prefix("p", claim.fencing_token)
        keys = vcat(
            ["$(prefix)/$(name)" for name in SatelliteSimPlatformRuntime.RUNNER_ARTIFACT_NAMES],
            ["$(prefix)/$(SatelliteSimPlatformRuntime.ARTIFACT_INDEX_NAME)"])
        ok = finalize_job!(store; job_id="job-final", worker_id="w1",
            fencing_token=claim.fencing_token, terminal_state="succeeded",
            artifact_keys=keys, artifact_prefix=prefix)
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

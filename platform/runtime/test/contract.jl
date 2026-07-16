# Contract tests for the ten runtime operations plus the deterministic
# end-to-end closure driven by walker8-local-v1.json.

@testset "contract" begin
    @testset "health and capabilities" begin
        service = make_service()
        health = runtime_health(service)
        @test health["status"] == "ok"
        @test health["worker_available"] == true
        @test health["schema_version"] == "satellitesim.experiment/v1"

        caps = runtime_capabilities(service)
        @test haskey(caps["resource_profiles"], "small")
        @test haskey(caps["resource_profiles"], "standard")
        @test caps["default_resource_profile"] == "small"
        @test "IDEMPOTENCY_CONFLICT" in caps["error_codes"]
        @test caps["limits"]["max_steps"] == 2_000
        @test length(caps["artifact_names"]) == 4
    end

    @testset "validate_experiment" begin
        service = make_service()
        result = validate_experiment(service, submitter(), raw_config())
        @test result["valid"] == true
        @test length(result["config_sha256"]) == 64
        @test result["admission"]["steps"] == 3
        @test result["admission"]["satellites"] == 8
        @test result["resource_profile"] == "small"

        @test_throws RuntimeError validate_experiment(service, submitter(), raw_config();
            resource_profile="gigantic")

        oversize = raw_config()
        oversize["steps"] = 3_000
        err = try
            validate_experiment(service, submitter(), oversize)
            nothing
        catch e
            e
        end
        @test err isa RuntimeError && err.code == "RUNTIME_POLICY_REJECTED"
    end

    @testset "named constellation resolution at admission" begin
        service = make_service()

        # a known catalog name resolves to its real satellite count
        named = raw_config()
        named["constellation"] = "walker24"
        result = validate_experiment(service, submitter(), named)
        @test result["valid"] == true
        @test result["admission"]["satellites"] == 24

        # a catalog name over the satellite limit is rejected on its real T
        toolarge = raw_config()
        toolarge["constellation"] = "kuiper"  # T = 1156 <= 2048, use steps to trip T*steps
        toolarge["steps"] = 2_000              # 1156 * 2000 > 2_000_000
        err = try
            validate_experiment(service, submitter(), toolarge)
            nothing
        catch e
            e
        end
        @test err isa RuntimeError && err.code == "RUNTIME_POLICY_REJECTED"

        # an unknown name is rejected outright, at validate and at submit
        unknown = raw_config()
        unknown["constellation"] = "not-a-constellation"
        err2 = try
            validate_experiment(service, submitter(), unknown)
            nothing
        catch e
            e
        end
        @test err2 isa RuntimeError && err2.code == "RUNTIME_POLICY_REJECTED"
        err3 = try
            submit_experiment(service, submitter(), unknown; idempotency_key="named-unknown")
            nothing
        catch e
            e
        end
        @test err3 isa RuntimeError && err3.code == "RUNTIME_POLICY_REJECTED"
        @test isempty(list_jobs_view(service, submitter())["jobs"])
    end

    @testset "submit idempotency and conflict" begin
        service = make_service()
        first = submit_experiment(service, submitter(), raw_config(); idempotency_key="key-1")
        @test first["state"] == "queued"
        @test first["idempotent"] == false

        replay = submit_experiment(service, submitter(), raw_config(); idempotency_key="key-1")
        @test replay["job_id"] == first["job_id"]
        @test replay["idempotent"] == true

        conflicting = raw_config()
        conflicting["alpha"] = 0.7
        err = try
            submit_experiment(service, submitter(), conflicting; idempotency_key="key-1")
            nothing
        catch e
            e
        end
        @test err isa RuntimeError && err.code == "IDEMPOTENCY_CONFLICT"
    end

    @testset "authorization boundary" begin
        service = make_service()
        err = try
            submit_experiment(service, reader(), raw_config(); idempotency_key="key-ro")
            nothing
        catch e
            e
        end
        @test err isa RuntimeError && err.code == "FORBIDDEN"
    end

    @testset "get/list and tenant scoping" begin
        service = make_service()
        job = submit_experiment(service, submitter(), raw_config(); idempotency_key="key-2")
        fetched = get_job_view(service, submitter(), job["job_id"])
        @test fetched["job_id"] == job["job_id"]

        @test_throws RuntimeError get_job_view(service, submitter(), "job-does-not-exist")
        # another tenant cannot observe this job
        @test_throws RuntimeError get_job_view(service, other_tenant(), job["job_id"])

        listing = list_jobs_view(service, submitter())
        @test listing["count"] >= 1
        @test any(j -> j["job_id"] == job["job_id"], listing["jobs"])
    end

    @testset "deterministic end-to-end success closure" begin
        service = make_service()
        submitted = submit_experiment(service, submitter(), raw_config(); idempotency_key="e2e")
        outcome = process_next_job!(service)
        @test outcome.status == :succeeded
        @test outcome.job_id == submitted["job_id"]
        @test length(outcome.artifact_keys) == 4

        job = get_job_view(service, submitter(), submitted["job_id"])
        @test job["state"] == "succeeded"
        @test length(job["artifact_keys"]) == 4

        artifacts = get_artifacts(service, submitter(), submitted["job_id"])
        @test length(artifacts["artifacts"]) == 3
        @test Set(a["name"] for a in artifacts["artifacts"]) ==
            Set(["config.snapshot.json", "result.json", "run_metadata.json"])

        result = read_result(service, submitter(), submitted["job_id"])
        @test result["result"]["deterministic"] == true
        @test result["result"]["steps"] == 3

        # a second identical run produces byte-identical result.json (determinism)
        service2 = make_service()
        job2 = submit_experiment(service2, submitter(), raw_config(); idempotency_key="e2e")
        process_next_job!(service2)
        r2 = read_result(service2, submitter(), job2["job_id"])
        @test r2["result"] == result["result"]
    end

    @testset "artifact/result readiness guards" begin
        service = make_service()
        pending = submit_experiment(service, submitter(), raw_config(); idempotency_key="pending")
        err = try
            read_result(service, submitter(), pending["job_id"])
            nothing
        catch e
            e
        end
        @test err isa RuntimeError && err.code == "ARTIFACT_NOT_READY"
        err2 = try
            get_artifacts(service, submitter(), pending["job_id"])
            nothing
        catch e
            e
        end
        @test err2 isa RuntimeError && err2.code == "ARTIFACT_NOT_READY"
    end

    @testset "cancel queued and running" begin
        service = make_service()
        queued = submit_experiment(service, submitter(), raw_config(); idempotency_key="cancel-q")
        cancelled = cancel_job(service, submitter(), queued["job_id"])
        @test cancelled["state"] == "cancelled"
        # cancel is idempotent on a terminal cancelled job
        again = cancel_job(service, submitter(), queued["job_id"])
        @test again["state"] == "cancelled"

        running = submit_experiment(service, submitter(), raw_config(); idempotency_key="cancel-r")
        service.backend.behaviors[running["job_id"]] = :timeout
        outcome = process_next_job!(service;
            on_running = job -> cancel_job(service, submitter(), job.id))
        @test outcome.status == :cancelled
        @test get_job_view(service, submitter(), running["job_id"])["state"] == "cancelled"
    end

    @testset "execution failure and timeout mapping" begin
        service = make_service()
        failing = submit_experiment(service, submitter(), raw_config(); idempotency_key="fail")
        service.backend.behaviors[failing["job_id"]] = :fail
        outcome = process_next_job!(service)
        @test outcome.status == :failed
        job = get_job_view(service, submitter(), failing["job_id"])
        @test job["state"] == "failed"
        @test job["error"]["code"] == "EXECUTION_FAILED"

        base = DateTime(2026, 1, 1)
        step = Ref(0)
        stepping = () -> (step[] += 1; base + Second(step[] * 3600))
        timeout_service = make_service(clock=stepping)
        slow = submit_experiment(timeout_service, submitter(), raw_config(); idempotency_key="slow")
        timeout_service.backend.behaviors[slow["job_id"]] = :timeout
        # the stepping clock advances one hour per call, so keep the lease alive
        # long enough that the run dies on the profile timeout, not the lease
        toutcome = process_next_job!(timeout_service; lease_seconds=30 * 24 * 3600)
        @test toutcome.status == :failed
        @test get_job_view(timeout_service, submitter(), slow["job_id"])["error"]["code"] == "EXECUTION_TIMEOUT"
    end

    @testset "reproduce_job lineage" begin
        service = make_service()
        source = submit_experiment(service, submitter(), raw_config(); idempotency_key="repro-src")
        process_next_job!(service)
        child = reproduce_job(service, submitter(), source["job_id"]; idempotency_key="repro-child")
        @test child["parent_job_id"] == source["job_id"]
        @test child["state"] == "queued"
        @test child["config_sha256"] == source["config_sha256"]
    end

    @testset "reproduce_job may not lower the source profile" begin
        service = make_service()
        source = submit_experiment(service, submitter(), raw_config();
            idempotency_key="repro-std", resource_profile="standard")
        process_next_job!(service)
        err = try
            reproduce_job(service, submitter(), source["job_id"];
                idempotency_key="repro-down", resource_profile="small")
            nothing
        catch e
            e
        end
        @test err isa RuntimeError && err.code == "RUNTIME_POLICY_REJECTED"

        # equal or higher profiles remain allowed
        same = reproduce_job(service, submitter(), source["job_id"];
            idempotency_key="repro-same", resource_profile="standard")
        @test same["state"] == "queued"
    end
end

using Dates
using SatelliteSimPlatformControl
using SatelliteSimPlatformKubernetes
using SatelliteSimPlatformStorage
using Test

const VALID_CONFIG = Dict{String,Any}(
    "schema_version" => "satellitesim.experiment/v1",
    "name" => "control-plane-smoke",
    "constellation" => Dict("T" => 4, "P" => 2, "F" => 1, "alt_km" => 550.0, "inc_deg" => 53.0),
    "propagator" => "two_body",
    "tspan" => [0.0, 60.0],
    "steps" => 2,
    "topology_strategy" => "balanced",
    "routing_algorithm" => "dijkstra",
    "traffic" => "uniform",
    "ground_pairs" => Any[],
    "random_seed" => 7,
    "alpha" => 0.5,
)

function test_plane(root)
    verifier = StaticIdentityVerifier(Dict(
        "local-alpha" => AuthenticatedPrincipal("alpha", "alice", [:submit]),
        "local-beta" => AuthenticatedPrincipal("beta", "bob", [:submit]),
        "local-read" => AuthenticatedPrincipal("alpha", "reader", [:read]),
    ))
    quotas = InMemoryQuotaStore()
    policy = QuotaPolicy(
        max_concurrent_jobs=1,
        max_cpu_millicores=2000,
        max_memory_mib=4096,
        max_daily_jobs=4,
        max_artifact_bytes=10_000,
    )
    set_quota_policy!(quotas, "alpha", policy)
    set_quota_policy!(quotas, "beta", policy)
    storage = LocalFilesystemStorage(joinpath(root, "objects"))
    client = FakeKubernetesJobClient()
    plane = PlatformControlPlane(
        verifier, quotas, storage, client;
        image="ghcr.io/satellitesim/runner:2026-07-09",
    )
    return plane, quotas, storage, client
end

@testset "identity and tenant-local quota contract" begin
    verifier = StaticIdentityVerifier(Dict(
        "dev" => AuthenticatedPrincipal("alpha", "alice", [:submit]),
        "read" => AuthenticatedPrincipal("alpha", "reader", [:read]),
    ))
    @test authenticate(verifier, "dev").subject == "alice"
    @test_throws AuthorizationError authenticate(verifier, "unknown")
    @test_throws AuthorizationError authorize_submission!(authenticate(verifier, "read"))
    @test_throws AuthorizationError AuthenticatedPrincipal("Alpha", "alice", [:submit])

    quotas = InMemoryQuotaStore()
    set_quota_policy!(quotas, "alpha", QuotaPolicy(
        max_concurrent_jobs=1, max_cpu_millicores=1000, max_memory_mib=2048,
        max_daily_jobs=2, max_artifact_bytes=100,
    ))
    alpha = authenticate(verifier, "dev")
    at = DateTime(2026, 7, 9, 12)
    first = reserve_quota!(quotas, alpha, "job-1", KubernetesResources(500, 512); artifact_bytes=40, now_utc=at)
    @test reserve_quota!(quotas, alpha, "job-1", KubernetesResources(500, 512); artifact_bytes=40, now_utc=at) === first
    usage = usage_snapshot(quotas, "alpha"; at_utc=at)
    @test (usage.concurrent_jobs, usage.cpu_millicores, usage.memory_mib, usage.daily_jobs, usage.artifact_bytes) == (1, 500, 512, 1, 40)
    @test_throws QuotaError reserve_quota!(quotas, alpha, "job-2", KubernetesResources(500, 512); artifact_bytes=40, now_utc=at)
    @test release_quota!(quotas, first; now_utc=at).state == :released
    @test usage_snapshot(quotas, "alpha"; at_utc=at).concurrent_jobs == 0
    @test_throws QuotaError reserve_quota!(quotas, alpha, "job-2", KubernetesResources(1001, 512); artifact_bytes=1, now_utc=at)
    @test_throws QuotaError reserve_quota!(quotas, alpha, "job-2", KubernetesResources(500, 512); artifact_bytes=101, now_utc=at)
end

@testset "authenticated control-plane submission is idempotent and isolated" begin
    mktempdir() do root
        plane, quotas, storage, client = test_plane(root)
        resources = KubernetesResources(1000, 2048)
        receipt = submit_experiment!(
            plane, "local-alpha", VALID_CONFIG;
            idempotency_key="walk-001", resources=resources, artifact_bytes=1024, request_id="request-001",
        )
        @test receipt.tenant_id == "alpha"
        @test receipt.subject == "alice"
        @test receipt.state == :submitted
        @test receipt.config_key == "tenants/alpha/configs/walk-001.json"
        @test receipt.output_prefix == "tenants/alpha/jobs/walk-001"
        @test has_object(storage, receipt.config_key)
        @test get_json(storage, receipt.config_key)["name"] == "control-plane-smoke"
        record = get_job_status(client, receipt.kubernetes_job_name)
        @test record !== nothing
        @test record.manifest["metadata"]["labels"]["satellitesim.io/tenant"] == "alpha"
        container = only(record.manifest["spec"]["template"]["spec"]["containers"])
        @test [env["value"] for env in container["env"]] == [
            "alpha-walk-001", receipt.config_key, receipt.output_prefix,
        ]

        repeated = submit_experiment!(
            plane, "local-alpha", copy(VALID_CONFIG);
            idempotency_key="walk-001", resources=resources, artifact_bytes=1024, request_id="request-001",
        )
        @test repeated === receipt
        @test length(list_submitted_jobs(client)) == 1
        @test length(list_submissions(plane)) == 1

        changed = copy(VALID_CONFIG)
        changed["name"] = "different"
        @test_throws ControlPlaneError submit_experiment!(
            plane, "local-alpha", changed;
            idempotency_key="walk-001", resources=resources, artifact_bytes=1024,
        )
        @test_throws QuotaError submit_experiment!(
            plane, "local-alpha", VALID_CONFIG;
            idempotency_key="walk-002", resources=resources, artifact_bytes=1024,
        )

        beta = submit_experiment!(
            plane, "local-beta", VALID_CONFIG;
            idempotency_key="walk-001", resources=resources, artifact_bytes=1024,
        )
        @test beta.tenant_id == "beta"
        @test beta.kubernetes_job_name != receipt.kubernetes_job_name
        @test length(list_submissions(plane; tenant_id="alpha")) == 1
        @test length(list_submissions(plane; tenant_id="beta")) == 1
        @test get_submission(plane, "beta", "walk-001") === beta
        @test get_submission(plane, "alpha", "missing") === nothing

        @test set_job_status!(client, receipt.kubernetes_job_name, :running).state == :running
        @test sync_submission!(plane, receipt).state == :running
        @test set_job_status!(client, receipt.kubernetes_job_name, :succeeded).state == :succeeded
        @test sync_submission!(plane, receipt).state == :succeeded
        @test usage_snapshot(quotas, "alpha").concurrent_jobs == 0
        resumed = submit_experiment!(
            plane, "local-alpha", VALID_CONFIG;
            idempotency_key="walk-002", resources=resources, artifact_bytes=1024,
        )
        @test resumed.state == :submitted
        @test cancel_submission!(plane, resumed).state == :cancelled
        @test usage_snapshot(quotas, "alpha").concurrent_jobs == 0
    end
end

@testset "control plane rejects invalid config, unsafe image, and unauthorized caller" begin
    mktempdir() do root
        plane, _, _, _ = test_plane(root)
        invalid = Dict("name" => "missing constellation")
        @test_throws ControlPlaneError submit_experiment!(plane, "local-alpha", invalid; idempotency_key="bad-config")
        @test_throws AuthorizationError submit_experiment!(plane, "local-read", VALID_CONFIG; idempotency_key="no-role")
        verifier = StaticIdentityVerifier(Dict("dev" => AuthenticatedPrincipal("alpha", "alice", [:submit])))
        quotas = InMemoryQuotaStore()
        set_quota_policy!(quotas, "alpha", QuotaPolicy(
            max_concurrent_jobs=1, max_cpu_millicores=1000, max_memory_mib=2048,
            max_daily_jobs=1, max_artifact_bytes=1000,
        ))
        @test_throws KubernetesSubmissionError PlatformControlPlane(
            verifier, quotas, LocalFilesystemStorage(joinpath(root, "unsafe")), FakeKubernetesJobClient();
            image="ghcr.io/satellitesim/runner:latest",
        )
    end
end

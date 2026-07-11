using SatelliteSimPlatformKubernetes
using Test

@testset "restricted Kubernetes Job renderer" begin
    spec = KubernetesJobSpec(
        job_id="experiment_42",
        namespace="satellitesim",
        image="ghcr.io/satellitesim/runner:2026-07-09",
        service_account="satellitesim-runner",
        config_key="tenants/alpha/configs/experiment_42.json",
        output_prefix="tenants/alpha/jobs/experiment_42",
        resources=KubernetesResources(1500, 3072),
        ttl_seconds_after_finished=7200,
        backoff_limit=1,
        labels=Dict("satellitesim.io/tenant" => "alpha"),
        annotations=Dict("satellitesim.io/request-id" => "req-42"),
    )
    rendered = render_job(spec)
    rerendered = render_job(spec)
    @test rendered.name == rerendered.name
    @test startswith(rendered.name, "satellitesim-experiment-42-")
    @test length(rendered.name) <= 63

    manifest = rendered.manifest
    @test manifest["apiVersion"] == "batch/v1"
    @test manifest["kind"] == "Job"
    @test manifest["metadata"]["namespace"] == "satellitesim"
    @test manifest["spec"]["backoffLimit"] == 1
    @test manifest["spec"]["ttlSecondsAfterFinished"] == 7200
    pod = manifest["spec"]["template"]["spec"]
    container = only(pod["containers"])
    @test pod["restartPolicy"] == "Never"
    @test pod["serviceAccountName"] == "satellitesim-runner"
    @test pod["automountServiceAccountToken"] == false
    @test !haskey(pod, "hostNetwork")
    @test !haskey(pod, "volumes")
    @test container["securityContext"]["allowPrivilegeEscalation"] == false
    @test container["securityContext"]["readOnlyRootFilesystem"] == true
    @test container["securityContext"]["capabilities"]["drop"] == ["ALL"]
    @test container["resources"]["limits"] == container["resources"]["requests"]
    @test [item["name"] for item in container["env"]] == [
        "SATSIM_JOB_ID", "SATSIM_CONFIG_KEY", "SATSIM_OUTPUT_PREFIX",
    ]
    @test !haskey(container, "command")
    @test !haskey(container, "args")
end

@testset "Kubernetes Job renderer rejects unsafe public inputs" begin
    common = (
        job_id="job-1",
        image="ghcr.io/satellitesim/runner:1.0.0",
        config_key="configs/job-1.json",
        output_prefix="jobs/job-1",
    )
    @test_throws KubernetesSubmissionError KubernetesJobSpec(; common..., image="ghcr.io/satellitesim/runner:latest")
    @test_throws KubernetesSubmissionError KubernetesJobSpec(; common..., namespace="Platform_System")
    @test_throws KubernetesSubmissionError KubernetesJobSpec(; common..., service_account="default")
    @test_throws KubernetesSubmissionError KubernetesJobSpec(; common..., config_key="../etc/passwd")
    @test_throws KubernetesSubmissionError KubernetesJobSpec(; common..., output_prefix="jobs\\escape")
    @test_throws KubernetesSubmissionError KubernetesJobSpec(; common..., resources=KubernetesResources(0, 2048))
    @test_throws KubernetesSubmissionError KubernetesJobSpec(; common..., labels=Dict("arbitrary" => "no"))
    @test_throws KubernetesSubmissionError KubernetesJobSpec(; common..., annotations=Dict("evil" => "no"))
end

@testset "fake Kubernetes client lifecycle" begin
    client = FakeKubernetesJobClient()
    rendered = render_job(KubernetesJobSpec(
        job_id="job-lifecycle",
        image="ghcr.io/satellitesim/runner:1.0.0",
        config_key="configs/job-lifecycle.json",
        output_prefix="jobs/job-lifecycle",
    ))
    record = submit_job!(client, rendered)
    @test record.state == :submitted
    @test get_job_status(client, rendered.name) === record
    @test_throws KubernetesSubmissionError submit_job!(client, rendered)
    @test set_job_status!(client, rendered.name, :running).state == :running
    @test cancel_job!(client, rendered.name).state == :cancelled
    @test cancel_job!(client, rendered.name).state == :cancelled
    @test_throws KubernetesSubmissionError set_job_status!(client, rendered.name, :running)
    @test only(list_submitted_jobs(client)) === record
end

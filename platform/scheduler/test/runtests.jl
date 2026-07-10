using SatelliteSimPlatformScheduler
using SatelliteSimPlatformStorage
using Test

const VALID_CONFIG = Dict{String,Any}(
    "schema_version" => "satellitesim.experiment/v1",
    "name" => "fake-scheduler-smoke",
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

@testset "fake scheduler preserves runner artifact contract" begin
    mktempdir() do root
        storage = LocalFilesystemStorage(joinpath(root, "objects"))
        scheduler = FakeScheduler(storage; work_root=joinpath(root, "work"))
        put_json!(storage, "configs/smoke.json", VALID_CONFIG)

        job = submit!(scheduler, "configs/smoke.json"; job_id="job-smoke")
        @test job.state == :queued
        @test job.output_prefix == "jobs/job-smoke"
        @test length(list_jobs(scheduler)) == 1

        completed = run_next!(scheduler)
        @test completed === job
        @test completed.state == :succeeded
        @test completed.error_message === nothing
        @test completed.started_at_utc !== nothing
        @test completed.finished_at_utc !== nothing
        @test [split(key, '/')[end] for key in completed.artifact_keys] == [
            "artifacts.index.json", "config.snapshot.json", "result.json", "run_metadata.json",
        ]
        @test has_object(storage, "jobs/job-smoke/result.json")
        @test get_json(storage, "jobs/job-smoke/run_metadata.json")["random_seed"] == 7
        @test run_next!(scheduler) === nothing
    end
end

@testset "fake scheduler failure and request validation" begin
    mktempdir() do root
        storage = LocalFilesystemStorage(joinpath(root, "objects"))
        scheduler = FakeScheduler(storage; work_root=joinpath(root, "work"))
        @test_throws SchedulerError submit!(scheduler, "configs/missing.json")

        put_json!(storage, "configs/invalid.json", Dict("name" => "missing constellation"))
        job = submit!(scheduler, "configs/invalid.json"; job_id="job-invalid")
        completed = only(run_all!(scheduler))
        @test completed === job
        @test completed.state == :failed
        @test completed.error_message !== nothing
        @test isempty(completed.artifact_keys)

        @test_throws SchedulerError submit!(scheduler, "configs/invalid.json"; job_id="bad/id")
    end
end

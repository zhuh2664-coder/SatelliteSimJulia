using Test
using JSON
using SatelliteSimPlatformBenchmarks

@testset "constellation optimization v1 is reproducible" begin
    scenario = load_scenario()
    baseline = load_baseline()
    @test scenario["benchmark_id"] == BENCHMARK_ID
    @test baseline["baseline_version"] == 1

    result = run_constellation_benchmark()
    @test verify_benchmark_result(result)
    @test result["dimensions"] == Dict(
        "satellite_count" => 4,
        "ground_point_count" => 12,
        "time_step_count" => 3,
        "optimized_parameter_count" => 2,
    )
    @test result["measurements"]["final_loss"] < result["measurements"]["initial_loss"]
    @test result["measurements"]["improvement_percent"] >= 0.1
    @test result["timing"]["elapsed_s"] >= 0

    mktempdir() do directory
        path = joinpath(directory, "result.json")
        @test write_benchmark_result(path, result) == path
        recovered = JSON.parsefile(path)
        @test verify_benchmark_result(recovered)
    end
end

@testset "constellation optimization v1 rejects numerical drift and malformed input" begin
    result = run_constellation_benchmark()
    drifted = JSON.parse(JSON.json(result))
    drifted["measurements"]["final_loss"] = 1.0
    @test_throws BenchmarkContractError verify_benchmark_result(drifted)

    mktempdir() do directory
        malformed = joinpath(directory, "scenario.json")
        write(malformed, "{\"benchmark_id\":\"$(BENCHMARK_ID)\"}")
        @test_throws BenchmarkContractError load_scenario(malformed)
    end
end

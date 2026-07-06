# results_routes.jl — lightweight route helper checks

using Test
using PlatformAPI

@testset "result route helpers" begin
    @test PlatformAPI._safe_result_filename("result.json")
    @test PlatformAPI._safe_result_filename("artifacts.index.json")
    @test PlatformAPI._safe_result_filename("nested/run_metadata.json")
    @test PlatformAPI._target_queryparams("/api/jobs/x/download?file=artifacts.index.json")["file"] == "artifacts.index.json"

    @test !PlatformAPI._safe_result_filename("")
    @test !PlatformAPI._safe_result_filename("/etc/passwd")
    @test !PlatformAPI._safe_result_filename("../secret")
    @test !PlatformAPI._safe_result_filename("nested/../secret")
    @test !PlatformAPI._safe_result_filename("nested\\secret")
end

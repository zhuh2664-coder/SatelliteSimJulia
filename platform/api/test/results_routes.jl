# results_routes.jl — lightweight route helper checks

using Test
using JSON
using SHA
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

@testset "artifact index fallback" begin
    existing = Vector{UInt8}(codeunits("{\"files\":[]}"))
    requested = String[]
    direct = PlatformAPI._artifact_index_data("s3://results/job"; downloader = key -> begin
        push!(requested, key)
        return existing
    end)
    @test direct == existing
    @test requested == ["s3://results/job/artifacts.index.json"]

    primary = Dict(
        "result.json" => Vector{UInt8}(codeunits("{\"ok\":true}")),
        "config.snapshot.json" => Vector{UInt8}(codeunits("{\"cfg\":1}")),
        "run_metadata.json" => Vector{UInt8}(codeunits("{\"run\":1}")),
    )
    fallback = PlatformAPI._artifact_index_data("s3://results/job/"; downloader = key -> begin
        name = split(key, "/")[end]
        name == "artifacts.index.json" && throw(ErrorException("NoSuchKey: $key"))
        return primary[name]
    end)
    parsed = JSON.parse(String(fallback))
    @test length(parsed["files"]) == 3
    result_entry = only(filter(item -> item["path"] == "result.json", parsed["files"]))
    @test result_entry["role"] == "result"
    @test result_entry["content_type"] == "application/json"
    @test result_entry["bytes"] == length(primary["result.json"])
    @test result_entry["sha256"] == bytes2hex(sha256(primary["result.json"]))

    partial = PlatformAPI._artifact_index_data("s3://results/job"; downloader = key -> begin
        name = split(key, "/")[end]
        name in ("artifacts.index.json", "config.snapshot.json") &&
            throw(ErrorException("NoSuchKey: $key"))
        return primary[name]
    end)
    partial_paths = [item["path"] for item in JSON.parse(String(partial))["files"]]
    @test partial_paths == ["result.json", "run_metadata.json"]

    @test_throws ErrorException PlatformAPI._artifact_index_data("s3://results/job"; downloader = key -> begin
        throw(ErrorException("NoSuchKey: $key"))
    end)

    @test_throws ErrorException PlatformAPI._artifact_index_data("s3://results/job"; downloader = key -> begin
        throw(ErrorException("Missing credentials"))
    end)
end

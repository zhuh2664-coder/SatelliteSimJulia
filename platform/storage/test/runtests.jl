using JSON
using SatelliteSimPlatformStorage
using Test

@testset "local filesystem storage contract" begin
    mktempdir() do root
        storage = LocalFilesystemStorage(root)
        first = put_bytes!(storage, "configs/example.txt", codeunits("hello"))
        @test first.key == "configs/example.txt"
        @test first.bytes == 5
        @test length(first.sha256) == 64
        @test has_object(storage, "configs/example.txt")
        @test String(get_bytes(storage, "configs/example.txt")) == "hello"
        @test object_metadata(storage, "configs/example.txt").sha256 == first.sha256

        json_object = put_json!(storage, "configs/example.json", Dict("schema_version" => "v1", "n" => 2))
        @test json_object.key == "configs/example.json"
        @test get_json(storage, "configs/example.json")["n"] == 2
        @test [object.key for object in list_objects(storage; prefix="configs")] == [
            "configs/example.json", "configs/example.txt",
        ]

        @test_throws StorageKeyError put_bytes!(storage, "../outside", UInt8[])
        @test_throws StorageKeyError put_bytes!(storage, "/absolute", UInt8[])
        @test_throws StorageKeyError put_bytes!(storage, "a//b", UInt8[])
        @test_throws KeyError get_bytes(storage, "configs/missing")
    end
end

@testset "directory transfer contract" begin
    mktempdir() do root
        mktempdir() do source
            mkpath(joinpath(source, "nested"))
            write(joinpath(source, "result.json"), JSON.json(Dict("fitness" => 1.0)))
            write(joinpath(source, "nested", "metadata.txt"), "metadata")

            storage = LocalFilesystemStorage(root)
            uploaded = upload_directory!(storage, "jobs/job-1", source)
            @test [object.key for object in uploaded] == [
                "jobs/job-1/nested/metadata.txt", "jobs/job-1/result.json",
            ]

            mktempdir() do destination
                materialized = materialize_prefix!(storage, "jobs/job-1", destination)
                @test length(materialized) == 2
                @test read(joinpath(destination, "result.json"), String) == read(joinpath(source, "result.json"), String)
                @test read(joinpath(destination, "nested", "metadata.txt"), String) == "metadata"
            end
        end
    end
end

using Test
using Dates
using JSON
using SatelliteSimPlatformRuntime
using SatelliteSimPlatformControl: AuthenticatedPrincipal, AuthorizationError
using SatelliteSimPlatformStorage: LocalFilesystemStorage

const EXAMPLE_CONFIG_PATH = normpath(joinpath(@__DIR__, "..", "..", "examples", "walker8-local-v1.json"))

raw_config() = JSON.parsefile(EXAMPLE_CONFIG_PATH)

submitter() = AuthenticatedPrincipal("tenant-a", "alice", Set([:submit, :read]))
reader() = AuthenticatedPrincipal("tenant-a", "bob", Set([:read]))
other_tenant() = AuthenticatedPrincipal("tenant-b", "carol", Set([:submit, :read]))

function make_service(; behaviors=Dict{String,Symbol}(), clock=() -> now(UTC),
                      storage_root=mktempdir(), store_path=":memory:")
    store = RuntimeJobStore(store_path)
    storage = LocalFilesystemStorage(storage_root)
    backend = DeterministicTestBackend(; behaviors=behaviors)
    return RuntimeApplicationService(store, storage, backend; clock=clock)
end

@testset "SatelliteSimPlatformRuntime" begin
    include("contract.jl")
    include("persistence.jl")
    include("lease_race.jl")
    include("characterization.jl")
end

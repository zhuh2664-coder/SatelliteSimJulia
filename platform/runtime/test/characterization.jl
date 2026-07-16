# Characterization tests pinning the existing behavior of the platform packages
# the runtime reuses. These guard against silent changes in packages we did not
# modify (PlatformRunner, Control, Storage, Kubernetes) that the runtime relies on.

using SatelliteSimPlatformStorage: LocalFilesystemStorage, put_json!, get_json,
    has_object, list_objects, object_metadata
using SatelliteSimPlatformControl: AuthenticatedPrincipal, AuthorizationError,
    authorize_submission!
using SatelliteSimPlatformKubernetes: KubernetesResources
using PlatformRunner: validate_experiment_config, PlatformConfigError,
    EXPERIMENT_SCHEMA_VERSION

@testset "characterization" begin
    @testset "PlatformRunner validation contract is unchanged" begin
        normalized = validate_experiment_config(raw_config())
        @test normalized["schema_version"] == EXPERIMENT_SCHEMA_VERSION
        @test normalized["constellation"]["T"] == 8
        @test normalized["steps"] == 3
        @test_throws PlatformConfigError validate_experiment_config(Dict{String,Any}())
    end

    @testset "Control principal and authorization are unchanged" begin
        @test_throws AuthorizationError AuthenticatedPrincipal("Tenant_A", "alice", Set([:submit]))
        @test_throws AuthorizationError AuthenticatedPrincipal("tenant-a", "alice", Set([:unknown]))
        @test authorize_submission!(AuthenticatedPrincipal("tenant-a", "alice", Set([:submit]))).subject == "alice"
        @test_throws AuthorizationError authorize_submission!(
            AuthenticatedPrincipal("tenant-a", "bob", Set([:read])))
    end

    @testset "LocalFilesystemStorage round-trip is unchanged" begin
        storage = LocalFilesystemStorage(mktempdir())
        put_json!(storage, "tenants/tenant-a/x.json", Dict("a" => 1))
        @test has_object(storage, "tenants/tenant-a/x.json")
        @test get_json(storage, "tenants/tenant-a/x.json")["a"] == 1
        meta = object_metadata(storage, "tenants/tenant-a/x.json")
        @test length(meta.sha256) == 64
        @test meta.key == "tenants/tenant-a/x.json"
        @test any(o -> o.key == "tenants/tenant-a/x.json", list_objects(storage; prefix="tenants"))
    end

    @testset "Kubernetes resource units are unchanged" begin
        resources = KubernetesResources(2_000, 8_192)
        @test resources.cpu_millicores == 2_000
        @test resources.memory_mib == 8_192
        # runtime maps a profile onto the same shared resource unit
        @test to_k8s_resources(resource_profile("small")) == KubernetesResources(2_000, 8_192)
    end
end

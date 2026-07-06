using Test

@testset "platform api suite" begin
    include("results_routes.jl")

    if get(ENV, "SATSIM_RUN_PLATFORM_API_INTEGRATION", "0") == "1"
        include("tenant_isolation.jl")
    else
        @info "Skipping tenant isolation integration test; set SATSIM_RUN_PLATFORM_API_INTEGRATION=1 with local API/Postgres to enable it."
    end
end

# src/distributed/test/runtests.jl — SatelliteSimDistributed independent smoke tests

using SatelliteSimDistributed
using SatelliteSimCore
using SatelliteSimNet
using Test

@testset "SatelliteSimDistributed" begin
    @testset "exports and types" begin
        @test SatelliteServer isa DataType
        @test DistributedSimulation isa DataType
        @test init_server isa Function
        @test propagate_server isa Function
        @test evaluate_local_isls isa Function
        @test run_distributed_simulation isa Function
    end

    @testset "SatelliteServer local lifecycle" begin
        elems = generate_walker_delta(; T=6, P=2, F=0, alt_km=550.0, inc_deg=53.0)
        server = init_server(1, elems[1], GridPlusStrategy(), 6, 2)
        @test server isa SatelliteServer
        @test server.sat_id == 1
        @test !isempty(server.isl_neighbors)
        pos = propagate_server(server, 60.0; propagator=:two_body)
        @test length(pos) == 3
        @test all(isfinite, pos)
    end

    @testset "local ISL evaluation shape" begin
        elems = generate_walker_delta(; T=6, P=2, F=0, alt_km=550.0, inc_deg=53.0)
        server = init_server(1, elems[1], GridPlusStrategy(), 6, 2)
        pos_all = propagate_to_ecef(elems, [0.0, 60.0]; propagator=TwoBodyPropagator())
        server.current_position = vec(pos_all[1, 2, :])
        neighbor_positions = Dict{Int,Vector{Float64}}(
            nb => vec(pos_all[nb, 2, :]) for nb in server.isl_neighbors if 1 <= nb <= 6
        )
        results = evaluate_local_isls(server, neighbor_positions, LEO_DEFAULTS)
        @test results isa Vector{Tuple{Int,Bool,Float64}}
        @test length(results) <= length(server.isl_neighbors)
    end
end

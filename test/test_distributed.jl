# ===== distributed: init_server + isl_neighbors 动态候选 (H1) =====

using Test
using Random
using SatelliteSimDistributed: init_server, SatelliteServer
using SatelliteSimNet: NearestNeighborStrategy, isl_neighbors, generate_topology

@testset "distributed satellite_server" begin
    N = 8
    positions = rand(MersenneTwister(7), N, 1, 3) .* 1000.0
    nn = NearestNeighborStrategy(positions=positions, k=3)
    topo = generate_topology(nn, N, 2)

    @test isempty(topo.static_links)
    @test !isempty(topo.dynamic_candidates)

    neighbors = isl_neighbors(nn, 1, N, 2)
    @test !isempty(neighbors)
    @test all(1 .<= neighbors .<= N)
    @test 1 ∉ neighbors

    server = init_server(1, (id=1,), nn, N, 2)
    @test server isa SatelliteServer
    @test server.sat_id == 1
    @test !isempty(server.isl_neighbors)
    @test sort(server.isl_neighbors) == sort(neighbors)
end

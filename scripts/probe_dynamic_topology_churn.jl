#!/usr/bin/env julia

using Test
using SatelliteSimNet

function sorted_edges(edges)
    return sort!(collect(edges))
end

@testset "Dynamic topology churn probe" begin
    n_sat = 4
    positions = zeros(Float64, n_sat, 2, 3)

    # t=1 nearest-neighbor pairs: (1,2), (3,4)
    positions[1, 1, :] .= (0.0, 0.0, 0.0)
    positions[2, 1, :] .= (1.0, 0.0, 0.0)
    positions[3, 1, :] .= (10.0, 0.0, 0.0)
    positions[4, 1, :] .= (11.0, 0.0, 0.0)

    # t=2 nearest-neighbor pairs churn to: (1,3), (2,4)
    positions[1, 2, :] .= (0.0, 0.0, 0.0)
    positions[3, 2, :] .= (1.0, 0.0, 0.0)
    positions[2, 2, :] .= (10.0, 0.0, 0.0)
    positions[4, 2, :] .= (11.0, 0.0, 0.0)

    topo1 = generate_topology(
        NearestNeighborStrategy(positions=positions, k=1, time_step=1),
        n_sat,
        2,
    )
    topo2 = generate_topology(
        NearestNeighborStrategy(positions=positions, k=1, time_step=2),
        n_sat,
        2,
    )

    edges1 = sorted_edges(topo1.dynamic_candidates)
    edges2 = sorted_edges(topo2.dynamic_candidates)
    churn = length(symdiff(Set(edges1), Set(edges2)))

    @test fieldnames(NearestNeighborStrategy) == (:positions, :k, :time_step)
    @test isempty(topo1.static_links)
    @test isempty(topo2.static_links)
    @test edges1 == [(1, 2), (3, 4)]
    @test edges2 == [(1, 3), (2, 4)]
    @test churn == 4
    @test topo1.description == "NearestNeighbor(k=1)"

    tshape = generate_topology(TShapeStrategy(), 6, 3)
    @test !isempty(tshape.static_links)
    @test !isempty(tshape.dynamic_candidates)
end

println("DYNAMIC TOPOLOGY CHURN: ALL PASS")

# src/security/test/runtests.jl — SatelliteSimSecurity independent smoke tests
#
# Defensive simulation tests for fault injection and blue/red-team types.

using SatelliteSimSecurity
using Test

@testset "SatelliteSimSecurity" begin
    @testset "attack type hierarchy" begin
        @test AbstractAttack isa DataType
        @test AbstractNetworkAttack <: AbstractAttack
        @test AbstractGroundAttack <: AbstractAttack
        @test AbstractRFAttack <: AbstractAttack
        @test AbstractPayloadAttack <: AbstractAttack
    end

    @testset "fault scenario attack on adjacency" begin
        adj = fill(Inf, 4, 4)
        for i in 1:4
            adj[i, i] = 0.0
        end
        adj[1, 2] = adj[2, 1] = 1.0
        adj[2, 3] = adj[3, 2] = 1.0
        adj[3, 4] = adj[4, 3] = 1.0

        atk = FaultScenario("cut-2-3", Int[], [(2, 3)], 0, 1)
        out = attack!(copy(adj), atk)
        @test out[2, 3] == Inf
        @test out[3, 2] == Inf
        @test out[1, 2] == 1.0
    end

    @testset "fault scenario failed satellite" begin
        adj = ones(4, 4)
        for i in 1:4
            adj[i, i] = 0.0
        end
        atk = FaultScenario("sat-2-down", [2], Tuple{Int,Int}[], 0, 1)
        out = attack!(copy(adj), atk)
        @test all(isinf, out[2, :])
        @test all(isinf, out[:, 2])
    end

    @testset "capacity and cut helpers" begin
        adj = fill(Inf, 3, 3)
        for i in 1:3
            adj[i, i] = 0.0
        end
        adj[1, 2] = adj[2, 1] = 1000.0
        adj[2, 3] = adj[3, 2] = 1000.0
        total, satisfied, bottlenecks = measure_capacity(adj, [(1, 3, 10.0)], 100.0)
        @test total == 10.0
        @test satisfied >= 0.0
        @test bottlenecks isa Vector{Tuple{Int,Int}}
        cut_capacity, cut_edges = find_minimum_cut(adj, 1, 3)
        @test cut_capacity >= 0.0
        @test cut_edges isa Vector{Tuple{Int,Int}}
    end

    @testset "red/blue/arena exported types" begin
        @test AttackEffect isa DataType
        @test AbstractDetector isa DataType
        @test AnomalyThreshold isa DataType
        @test Verdict isa DataType
        @test ArenaState isa DataType
    end
end

# test_cgr.jl — Contact Graph Routing 测试

using SatelliteSimNet
using Test

@testset "CGR contact plan basics" begin
    cp = CGRContactPlan("test")
    @test cp.name == "test"
    @test isempty(cp.contacts)

    add_contact!(cp, UInt32(1), UInt32(2), 0.0, 10.0, 0.001)
    add_contact!(cp, UInt32(2), UInt32(3), 5.0, 15.0, 0.001)
    @test length(cp.contacts) == 2

    rebuild_adjacency!(cp)
    @test haskey(cp.adjacency, UInt32(1))
    @test UInt32(2) in cp.adjacency[UInt32(1)]

    @test length(active_contacts(cp, 6.0)) == 2
    @test length(active_contacts(cp, 11.0)) == 1
    @test isempty(active_contacts(cp, 20.0))

    stats = contact_stats(cp)
    @test stats[1] == 2
    @test stats[4] == 3  # 3 nodes
end

@testset "CGR simple route" begin
    cp = CGRContactPlan("chain")
    # 1 -> 2 -> 3, contacts overlap in time
    add_contact!(cp, UInt32(1), UInt32(2), 0.0, 10.0, 0.001)
    add_contact!(cp, UInt32(2), UInt32(3), 0.0, 10.0, 0.001)

    path, delay, arrival = cgr_route(cp, UInt32(1), UInt32(3), 0.0)
    @test path == UInt32[1, 2, 3]
    @test delay > 0.0
    @test isfinite(delay)
    @test arrival == 0.0 + delay
end

@testset "CGR route with wait" begin
    cp = CGRContactPlan("wait")
    # 1 -> 2 starts at 5s, 2 -> 3 starts at 5s
    add_contact!(cp, UInt32(1), UInt32(2), 5.0, 15.0, 0.001)
    add_contact!(cp, UInt32(2), UInt32(3), 5.0, 15.0, 0.001)

    path, delay, arrival = cgr_route(cp, UInt32(1), UInt32(3), 0.0)
    @test path == UInt32[1, 2, 3]
    @test delay >= 5.0
    @test isfinite(delay)
end

@testset "CGR unreachable" begin
    cp = CGRContactPlan("no_path")
    add_contact!(cp, UInt32(1), UInt32(2), 0.0, 10.0, 0.001)
    # No contact to node 3

    path, delay, arrival = cgr_route(cp, UInt32(1), UInt32(3), 0.0)
    @test isempty(path)
    @test delay == Inf
    @test arrival == Inf
end

@testset "CGR shortest path helper" begin
    cp = CGRContactPlan("sp")
    add_contact!(cp, UInt32(1), UInt32(2), 0.0, 10.0, 0.001)
    add_contact!(cp, UInt32(2), UInt32(3), 0.0, 10.0, 0.001)

    path = cgr_shortest_path(cp, UInt32(1), UInt32(3), 0.0)
    @test path == UInt32[1, 2, 3]

    nothing_path = cgr_shortest_path(cp, UInt32(1), UInt32(4), 0.0)
    @test nothing_path === nothing
end

@testset "CGR multipath" begin
    cp = CGRContactPlan("multi")
    # Two paths: 1->2->3 and 1->4->3
    add_contact!(cp, UInt32(1), UInt32(2), 0.0, 10.0, 0.001)
    add_contact!(cp, UInt32(2), UInt32(3), 0.0, 10.0, 0.001)
    add_contact!(cp, UInt32(1), UInt32(4), 0.0, 10.0, 0.002)
    add_contact!(cp, UInt32(4), UInt32(3), 0.0, 10.0, 0.002)

    paths = cgr_multipath(cp, UInt32(1), UInt32(3), 0.0; n_paths=3)
    @test length(paths) >= 2
    @test paths[1][1] == UInt32[1, 2, 3] || paths[1][1] == UInt32[1, 4, 3]
end

@testset "CGR ETO deadline" begin
    cp = CGRContactPlan("eto")
    add_contact!(cp, UInt32(1), UInt32(2), 0.0, 10.0, 0.001)
    add_contact!(cp, UInt32(2), UInt32(3), 0.0, 10.0, 0.001)

    # Tight deadline should fail
    path_fail, _, _ = cgr_eto(cp, UInt32(1), UInt32(3), 0.0, 0.0001)
    @test isempty(path_fail)

    # Loose deadline should succeed
    path_ok, _, _ = cgr_eto(cp, UInt32(1), UInt32(3), 0.0, 100.0)
    @test !isempty(path_ok)
end

@testset "CGR via AbstractRoutingAlgorithm interface" begin
    cp = CGRContactPlan("interface")
    add_contact!(cp, UInt32(1), UInt32(2), 0.0, 10.0, 0.001)
    add_contact!(cp, UInt32(2), UInt32(3), 0.0, 10.0, 0.001)

    out = route(CGRRouting(), cp, 1, 3, 0.0)
    @test out isa RoutingOutput
    @test out.path == [1, 2, 3]
    @test isfinite(out.total_weight)
    @test out.algorithm == "CGR"

    # Unreachable
    out_fail = route(CGRRouting(), cp, 1, 99, 0.0)
    @test isempty(out_fail.path)
    @test out_fail.total_weight == Inf
end

@testset "CGR route table" begin
    cp = CGRContactPlan("table")
    add_contact!(cp, UInt32(1), UInt32(2), 0.0, 10.0, 0.001)
    add_contact!(cp, UInt32(2), UInt32(3), 0.0, 10.0, 0.001)

    rt = CgrRouteTable(UInt32(1), cp; interval=0.0)
    update_routes!(rt, 0.0)
    @test haskey(rt.entries, UInt32(3))

    next_hop = get_next_hop(rt, UInt32(3))
    @test next_hop !== nothing
    @test next_hop[1] == UInt32(2)
end

@testset "CGR build from positions" begin
    # 3 satellites in a line, close enough for ISL
    pos = zeros(3, 5, 3)
    pos[1, :, :] .= [0.0 0.0 0.0]
    pos[2, :, :] .= [100.0 0.0 0.0]
    pos[3, :, :] .= [200.0 0.0 0.0]

    cp = CGRContactPlan()
    build_contact_plan_from_positions!(cp, pos, UInt32[1, 2, 3]; max_dist=5000.0, dt=1.0)

    @test length(cp.contacts) > 0
    stats = contact_stats(cp)
    @test stats[1] > 0
    @test stats[4] == 3
end

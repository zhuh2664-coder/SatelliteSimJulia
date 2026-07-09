# ===== PINN 训练/推理最小闭环 (opt + net) =====

using Test
using Random
using SatelliteSimOpt: train_pinn_routing, infer_pinn_latency, generate_pinn_training_samples
using SatelliteSimNet: PINNRoutingAlgorithm, build_routing_graph, route, RoutingInput, DijkstraRouting

@testset "PINN train/infer loop" begin
    adj = fill(Inf, 4, 4)
    for i in 1:4
        adj[i, i] = 0.0
    end
    adj[1, 2] = adj[2, 1] = 2.0
    adj[2, 3] = adj[3, 2] = 3.0
    adj[3, 4] = adj[4, 3] = 1.0
    adj[1, 4] = adj[4, 1] = 10.0

    src_list, dst_list, latency_list = generate_pinn_training_samples(
        adj; n_samples=8, sats_per_plane=2, n_planes=2, rng=MersenneTwister(1),
    )
    @test length(src_list) == 8
    @test all(isfinite, latency_list)

    pinn = train_pinn_routing(
        adj; n_samples=8, epochs=3, verbose=false, use_physics=false,
        sats_per_plane=2, n_planes=2, rng=MersenneTwister(2),
    )
    pred = infer_pinn_latency(pinn, adj, 1, 4)
    @test isfinite(pred)
    @test pred >= 0.0

    predict_fn(p, a, s, d) = infer_pinn_latency(p, a, s, d)
    alg = PINNRoutingAlgorithm(pinn, predict_fn; sats_per_plane=2, n_planes=2)
    graph = build_routing_graph(4, [(1, 2), (2, 3), (3, 4)], [2.0, 3.0, 1.0])
    result = route(alg, RoutingInput(graph, 1, 4))
    dijkstra = route(DijkstraRouting(), RoutingInput(graph, 1, 4))
    @test !isempty(result.path)
    @test result.path == dijkstra.path
    @test result.algorithm == "PINNRouting"
end

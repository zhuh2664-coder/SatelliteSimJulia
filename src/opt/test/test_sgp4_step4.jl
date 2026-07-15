using Test
using LinearAlgebra: norm
using SatelliteToolbox
using SatelliteSimOpt: full_isl_edge_list, edge_count,
                       network_kpi_config, network_kpi_loss_grad_positions,
                       network_kpi_loss_edges, network_kpi_loss_grad_positions_edges,
                       sgp4_network_kpi_gradient, sgp4_series_ecef, default_od_pairs

step4_grel(g, ref) = norm(vec(g) - vec(ref)) / max(norm(vec(ref)), 1e-12)
step4_loss_ok(value, ref, atol, rtol) = abs(value - ref) <= atol + rtol * abs(ref)

@testset "Step 4 edge-list AD" begin
    @testset "full-edge canonical topology" begin
        edges = full_isl_edge_list(9)
        @test edge_count(edges) == 9 * 8 ÷ 2
        @test all(edges.src .< edges.dst)
        @test issorted(collect(zip(edges.src, edges.dst)))
        @test length(unique(collect(zip(edges.src, edges.dst)))) == edge_count(edges)
        for i in 1:edges.N
            neighbours = edges.nbr_node[edges.nbr_off[i]:(edges.nbr_off[i + 1] - 1)]
            @test neighbours == sort(neighbours)
            @test neighbours == [j for j in 1:edges.N if j != i]
        end
    end

    @testset "dense and full-edge loss/dP equivalence" begin
        N, NT = 8, 3
        P = nk_synth_positions(N, NT)
        P .+= reshape(collect(1:length(P)), size(P)) .* 1e-4
        od = default_od_pairs(N; count=5)
        edges = full_isl_edge_list(N)
        common = (od_pairs=od, d_thresh=9000.0, τ=250.0, τsp=60.0,
                  bellman_K=N, penalty_km=5.0e5)

        for kind in (:latency, :reachability)
            cfg = network_kpi_config(N, NT; kind=kind, common...)
            loss_dense, dP_dense = network_kpi_loss_grad_positions(P, cfg)
            loss_edge = network_kpi_loss_edges(P, cfg, edges)
            loss_edge_ad, dP_edge = network_kpi_loss_grad_positions_edges(P, cfg, edges)

            @test step4_loss_ok(loss_edge, loss_dense, 1e-12, 1e-10)
            @test step4_loss_ok(loss_edge_ad, loss_dense, 1e-12, 1e-10)
            @test step4_grel(dP_edge, dP_dense) <= 1e-10
        end
    end

    @testset "dense and full-edge dθ equivalence" begin
        N, NT = 4, 3
        params, epochs = nk_read_params_epochs(N)
        jd_ref = maximum(epochs)
        ts_min = collect(range(0.0, 45.0; length=NT))
        gmsts = Float64[SatelliteToolbox.jd_to_gmst(jd_ref + t / 1440.0) for t in ts_min]
        positions = sgp4_series_ecef(params, epochs, ts_min, gmsts; jd_ref=jd_ref)
        distances = sort(Float64[
            norm(positions[i, 1, :] .- positions[j, 1, :])
            for i in 1:N for j in (i + 1):N
        ])
        od = default_od_pairs(N; count=3)
        common = (d_thresh=1.2 * distances[length(distances) ÷ 2], τ=700.0,
                  τsp=90.0, bellman_K=N, penalty_km=5.0e5)

        for kind in (:latency, :reachability)
            loss_dense, grad_dense = sgp4_network_kpi_gradient(
                params, epochs, ts_min; jd_ref=jd_ref, gmsts=gmsts,
                engine=:blockdiag, kind=kind, od_pairs=od, common...,
            )
            loss_edge, grad_edge = sgp4_network_kpi_gradient(
                params, epochs, ts_min; jd_ref=jd_ref, gmsts=gmsts,
                engine=:edge_monolithic, kind=kind, od_pairs=od, common...,
            )
            @test step4_loss_ok(loss_edge, loss_dense, 1e-12, 1e-10)
            @test step4_grel(grad_edge, grad_dense) <= 1e-10
        end
    end
end

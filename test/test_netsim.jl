using Test
using SatelliteSimNetSim

@testset "SatelliteSimNetSim" begin
    @testset "DropTailQueue" begin
        q = DropTailQueue(max_packets=2, max_bytes=10_000)
        p1 = create_packet!(100, 1, 2)
        p2 = create_packet!(100, 1, 2)
        p3 = create_packet!(100, 1, 2)
        @test enqueue!(q, p1)
        @test enqueue!(q, p2)
        @test !enqueue!(q, p3)
        @test drop_count(q) == 1
        @test packets_in_queue(q) == 2
        @test dequeue!(q) === p1
        @test packets_in_queue(q) == 1
    end

    @testset "simulate_path underload" begin
        hop_ms = [10.0, 10.0, 10.0]
        r = simulate_path(hop_ms, 100e6; load_bps=50e6, duration_s=0.5, poisson=false, seed=1)
        @test r.n_sent > 0
        @test r.n_dropped == 0
        @test r.n_delivered == r.n_sent
        @test isapprox(r.prop_delay_ms, 30.0; atol=1e-9)
        # Under CBR underload, queue delay should be ~0
        @test r.mean_queue_delay_ms < 0.5
    end

    @testset "simulate_path overload drops" begin
        hop_ms = [10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0]
        r = simulate_path(
            hop_ms,
            100e6;
            load_bps=130e6,
            duration_s=1.0,
            poisson=true,
            seed=42,
            max_packets=32,
        )
        @test r.n_sent > 0
        @test r.n_dropped > 0
        @test r.drop_ratio > 0.05
        @test r.mean_queue_delay_ms > 0.0
        @test sum(r.hop_drops) == r.n_dropped
    end

    @testset "demo_netsim" begin
        r = demo_netsim(load_mbps=130.0, rate_mbps=100.0, duration_s=0.5, seed=7)
        @test r isa PathSimResult
        @test r.n_sent > 0
    end
end

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

    @testset "ContactPlan + CGR" begin
        plan = ContactPlan()
        add_contact!(plan, 1, 2, 0.0, 10.0, 0.05)
        add_contact!(plan, 2, 3, 0.0, 10.0, 0.05)
        add_contact!(plan, 1, 3, 5.0, 15.0, 0.08)

        r0 = cgr_route(plan, 1, 3, 0.0)
        @test r0.reachable
        @test r0.path == UInt32[1, 2, 3]
        @test isapprox(r0.total_delay_s, 0.10; atol=1e-9)

        r5 = cgr_route(plan, 1, 3, 5.0)
        @test r5.reachable
        @test r5.path == UInt32[1, 3]
        @test isapprox(r5.total_delay_s, 0.08; atol=1e-9)

        # At t=12 the direct 1→3 contact (ends at 15) is still best
        add_contact!(plan, 1, 4, 12.0, 20.0, 0.04)
        add_contact!(plan, 4, 3, 14.0, 22.0, 0.04)
        r12 = cgr_route(plan, 1, 3, 12.0)
        @test r12.reachable
        @test r12.path == UInt32[1, 3]
        @test isapprox(r12.arrival_time, 12.08; atol=1e-9)

        # Force store-and-forward when direct is gone and 1→2→3 has ended
        plan_sf = ContactPlan()
        add_contact!(plan_sf, 1, 4, 12.0, 20.0, 0.04)
        add_contact!(plan_sf, 4, 3, 14.0, 22.0, 0.04)
        add_contact!(plan_sf, 1, 3, 20.0, 30.0, 0.08)  # late direct
        r_sf = cgr_route(plan_sf, 1, 3, 12.0)
        @test r_sf.reachable
        @test r_sf.path == UInt32[1, 4, 3]
        @test r_sf.arrival_time >= 14.04 - 1e-9

        # build from positions
        plan2 = ContactPlan()
        pos = zeros(3, 2, 3)
        pos[1, 1, :] = [0.0, 0.0, 7000.0]
        pos[2, 1, :] = [1000.0, 0.0, 7000.0]
        pos[3, 1, :] = [2000.0, 0.0, 7000.0]
        pos[1, 2, :] = [0.0, 0.0, 7000.0]
        pos[2, 2, :] = [1000.0, 0.0, 7000.0]
        pos[3, 2, :] = [2000.0, 0.0, 7000.0]
        build_contact_plan_from_pos!(plan2, pos, [1, 2, 3]; max_dist_km=1500.0, dt=1.0)
        @test length(plan2.contacts) > 0
        @test cgr_route(plan2, 1, 3, 0.0).reachable
    end

    @testset "FlowMonitor" begin
        mon = FlowMonitor()
        record_tx!(mon, 1, 2, 1000, 80, 17, 100, 0.0)
        record_tx!(mon, 1, 2, 1000, 80, 17, 100, 0.01)
        record_rx!(mon, 1, 2, 1000, 80, 17, 100, 0.05, 0.05)
        record_drop!(mon, 1, 2, 1000, 80, 17)
        rows = flow_summary(mon)
        @test length(rows) == 1
        @test rows[1].tx_packets == 2
        @test rows[1].rx_packets == 1
        @test rows[1].lost_packets == 1
    end

    @testset "UDP helpers" begin
        h = UdpHeader(1234, 80, 100)
        @test h.length == UDP_HEADER_SIZE + 100
        @test udp_payload_bytes(100) == 108
    end

    @testset "TCP Reno simplified" begin
        # lightly loaded path — should complete transfer
        r = simulate_tcp_reno(
            [5.0, 5.0],
            50e6;
            total_bytes=10_000,
            mss_bytes=1000,
            max_packets=64,
            rto_s=0.5,
            seed=1,
        )
        @test r.bytes_acked >= 10_000
        @test r.segments_sent >= 10
        @test r.duration_s > 0
        @test r.goodput_bps > 0
    end

    @testset "demos" begin
        r = demo_netsim(load_mbps=130.0, rate_mbps=100.0, duration_s=0.3, seed=7)
        @test r isa PathSimResult
        @test r.n_sent > 0
        rs = demo_cgr()
        @test rs[1].reachable
        tr = demo_tcp_reno(total_bytes=5_000)
        @test tr.bytes_acked >= 5_000
    end
end

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

    @testset "Bundle + store" begin
        reset_bundle_seq!()
        src = BundleEID("dtn://1/app")
        dst = BundleEID("dtn://2/app")
        @test string(src) == "dtn://1/app"
        data = Vector{UInt8}("payload-bytes")
        b = Bundle(src, dst, data; lifetime=10.0, creation_time=0.0)
        @test get_payload(b) == data
        @test !is_expired(b, 5.0)
        @test is_expired(b, 11.0)
        store = BundleStore(max_bundles=2)
        @test store_bundle!(store, b; now=0.0)
        @test take_bundle!(store) === b
        frags = fragment_bundle(b, 5)
        @test length(frags) >= 2
        reass = reassemble_bundles(frags)
        @test reass !== nothing
        @test get_payload(reass) == data
        ser = serialize_bundle(b)
        @test length(ser) > length(data)
    end

    @testset "LTP red/green" begin
        data = rand(UInt8, 1200)
        sess = LtpSession(7, 1, 2; segment_size=300)
        ltp_segment!(sess, data; red_bytes=900)
        st = ltp_stats(sess)
        @test st.red_segments == 3
        @test st.green_segments == 1
        @test st.red_pending == 3
        ltp_ack_red!(sess, [1, 2, 3])
        @test ltp_reassemble_red(sess) == data[1:900]
        @test ltp_reassemble_green(sess) == data[901:end]

        r0 = simulate_ltp_transfer(data; red_bytes=900, segment_size=300, loss=0.0, seed=1)
        @test r0.delivered_red
        @test r0.red_bytes == 900
        @test r0.green_bytes_rx == 300
        @test r0.retransmits == 0

        r_loss = simulate_ltp_transfer(data; red_bytes=900, segment_size=300, loss=0.3, seed=2)
        @test r_loss.delivered_red
        @test r_loss.drops > 0 || r_loss.retransmits > 0
    end

    @testset "DTN BPA forward" begin
        plan = ContactPlan()
        add_contact!(plan, 1, 4, 12.0, 20.0, 0.04)
        add_contact!(plan, 4, 3, 14.0, 22.0, 0.04)
        add_contact!(plan, 1, 3, 20.0, 30.0, 0.08)
        r = simulate_dtn_forward(plan, 1, 3, Vector{UInt8}("x"); t0=10.0)
        @test r.delivered
        @test r.path == UInt32[1, 4, 3]
        @test r.deferred >= 1
        @test r.delivery_time >= 14.04 - 1e-9
    end

    @testset "PCAP writer" begin
        path = joinpath(tempdir(), "satellitesim_test_$(getpid()).pcap")
        pw = open_pcap(path)
        write_pcap_packet!(pw, UInt8[1, 2, 3, 4]; t=1.5)
        pkt = create_packet!(64, 1, 2)
        write_pcap_packet!(pw, pkt; t=2.0)
        close_pcap!(pw)
        @test pw.packet_count == 2
        bytes = read(path)
        @test length(bytes) >= 24 + 16  # global + at least one record
        @test reinterpret(UInt32, bytes[1:4])[1] == 0xa1b2c3d4 ||
              reinterpret(UInt32, bytes[1:4])[1] == 0xd4c3b2a1
        rm(path; force=true)
    end

    @testset "dual fidelity + M/D/1 + ns-3 export" begin
        hop_ms = [10.0, 10.0, 10.0]
        df = compare_path_fidelity(hop_ms, 100e6; duration_s=0.4, seed=3)
        @test df.analytical_prop_ms ≈ 30.0 atol = 1e-9
        @test df.aligned
        @test df.underload.n_dropped == 0
        @test df.overload_drop_ratio > 0.0
        @test df.overload_queue_ms > 0.0

        md = compare_to_md1(5.0, 50e6; load_frac=0.6, duration_s=1.5, seed=2)
        @test md.rho ≈ 0.6 atol = 1e-9
        @test md.theory_wait_s > 0
        @test md.within_tol

        sc_path = joinpath(tempdir(), "ns3_sc_$(getpid()).json")
        export_ns3_scenario(sc_path, Ns3Scenario("t", hop_ms, 100e6, 1500, 130e6, 1.0, 32, 1))
        txt = read(sc_path, String)
        @test occursin("hop_prop_ms", txt)
        @test occursin("100000000", txt) || occursin("1.0e8", txt) || occursin("1.0e+8", txt)
        rm(sc_path; force=true)
    end

    @testset "demos" begin
        r = demo_netsim(load_mbps=130.0, rate_mbps=100.0, duration_s=0.3, seed=7)
        @test r isa PathSimResult
        @test r.n_sent > 0
        rs = demo_cgr()
        @test rs[1].reachable
        tr = demo_tcp_reno(total_bytes=5_000)
        @test tr.bytes_acked >= 5_000
        dr = demo_dtn()
        @test dr.delivered
        lr = demo_ltp(loss=0.15, seed=3)
        @test lr.delivered_red
        df, md = demo_dual_fidelity()
        @test df.aligned
        @test md.within_tol
    end
end

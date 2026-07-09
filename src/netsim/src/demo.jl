# Standalone NetSim demos (no SatelliteSim* deps)

export demo_netsim, demo_cgr, demo_tcp_reno, demo_dtn, demo_ltp, demo_dual_fidelity
export demo_aqm, demo_tcp_cubic

"""
    demo_netsim(; load_mbps=130.0, rate_mbps=100.0, duration_s=2.0)

Multi-hop DES demo: queueing delay / drops vs analytical prop delay.
"""
function demo_netsim(;
    load_mbps::Real=130.0,
    rate_mbps::Real=100.0,
    duration_s::Real=2.0,
    seed::Int=42,
)
    hop_ms = [10.5, 10.8, 11.2, 10.1, 10.9, 10.4, 10.0]
    println("="^60)
    println("SatelliteSimNetSim demo — packet-level DES")
    println("="^60)
    @printf("hops=%d  load=%.1f Mbps  capacity=%.1f Mbps  duration=%.1fs\n",
            length(hop_ms), load_mbps, rate_mbps, duration_s)

    result = simulate_path(
        hop_ms,
        rate_mbps * 1e6;
        load_bps=load_mbps * 1e6,
        duration_s=duration_s,
        poisson=true,
        seed=seed,
        max_packets=32,
    )

    # FlowMonitor on the same synthetic flow
    mon = FlowMonitor()
    for i in 1:result.n_sent
        record_tx!(mon, 1, 2, 5000, 80, 17, 1500, 0.0)
    end
    for (i, lat_ms) in enumerate(result.latency_samples_ms)
        record_rx!(mon, 1, 2, 5000, 80, 17, 1500, lat_ms / 1000, lat_ms / 1000)
    end
    for _ in 1:result.n_dropped
        record_drop!(mon, 1, 2, 5000, 80, 17)
    end

    println("-"^60)
    println("Analytical layer would only see:")
    @printf("  prop delay     : %.3f ms\n", result.prop_delay_ms)
    println("DES additionally reports:")
    @printf("  sent/deliv/drop: %d / %d / %d  (drop %.2f%%)\n",
            result.n_sent, result.n_delivered, result.n_dropped, 100 * result.drop_ratio)
    @printf("  e2e latency    : mean %.3f | p95 %.3f | max %.3f ms\n",
            result.mean_latency_ms, result.p95_latency_ms, result.max_latency_ms)
    @printf("  queue delay    : %.3f ms\n", result.mean_queue_delay_ms)
    println("FlowMonitor:")
    print_flow_stats(mon)
    println("="^60)
    return result
end

"""
    demo_cgr()

ContactPlan + CGR demo with a small time-varying topology.
"""
function demo_cgr()
    println("="^60)
    println("SatelliteSimNetSim demo — ContactPlan / CGR")
    println("="^60)
    plan = ContactPlan()
    # t∈[0,10): 1→2→3
    add_contact!(plan, 1, 2, 0.0, 10.0, 0.05)
    add_contact!(plan, 2, 3, 0.0, 10.0, 0.05)
    # t∈[5,15): shortcut 1→3 appears later
    add_contact!(plan, 1, 3, 5.0, 15.0, 0.08)
    # t∈[12,20): 1→4→3 via store-and-forward window
    add_contact!(plan, 1, 4, 12.0, 20.0, 0.04)
    add_contact!(plan, 4, 3, 14.0, 22.0, 0.04)

    r0 = cgr_route(plan, 1, 3, 0.0)
    r5 = cgr_route(plan, 1, 3, 5.0)
    r12 = cgr_route(plan, 1, 3, 12.0)

    @printf("t=0  path=%s  arrival=%.3fs  delay=%.3fs\n",
            string(Int.(r0.path)), r0.arrival_time, r0.total_delay_s)
    @printf("t=5  path=%s  arrival=%.3fs  delay=%.3fs  (uses shortcut)\n",
            string(Int.(r5.path)), r5.arrival_time, r5.total_delay_s)
    @printf("t=12 path=%s  arrival=%.3fs  delay=%.3fs  (direct still open)\n",
            string(Int.(r12.path)), r12.arrival_time, r12.total_delay_s)

    # store-and-forward when only 1→4→3 is early enough
    plan_sf = ContactPlan()
    add_contact!(plan_sf, 1, 4, 12.0, 20.0, 0.04)
    add_contact!(plan_sf, 4, 3, 14.0, 22.0, 0.04)
    add_contact!(plan_sf, 1, 3, 20.0, 30.0, 0.08)
    r_sf = cgr_route(plan_sf, 1, 3, 12.0)
    @printf("t=12 (no early direct) path=%s  arrival=%.3fs  (store-and-forward)\n",
            string(Int.(r_sf.path)), r_sf.arrival_time)

    st = contact_stats(plan)
    @printf("plan: %d contacts, %d nodes, mean delay %.2f ms\n",
            st.n_contacts, st.n_nodes, st.mean_delay_ms)
    println("="^60)
    return (r0, r5, r12, r_sf)
end

"""
    demo_tcp_reno(; load path overloaded)

Simplified TCP Reno over a short path.
"""
function demo_tcp_reno(; rate_mbps::Real=10.0, total_bytes::Int=20_000)
    println("="^60)
    println("SatelliteSimNetSim demo — TCP Reno (simplified)")
    println("="^60)
    hop_ms = [20.0, 20.0]  # ~40 ms one-way prop
    r = simulate_tcp_reno(
        hop_ms,
        rate_mbps * 1e6;
        total_bytes=total_bytes,
        mss_bytes=1000,
        max_packets=8,   # small buffers → some drops/RTOs
        rto_s=0.3,
        seed=7,
    )
    @printf("acked=%d / %d bytes  segs=%d  rexmit=%d  drops=%d  completed=%s\n",
            r.bytes_acked, total_bytes, r.segments_sent, r.retransmits, r.drops, string(r.completed))
    @printf("duration=%.3fs  goodput=%.3f Mbps  cwnd=%d  ssthresh=%d\n",
            r.duration_s, r.goodput_bps / 1e6, r.final_cwnd, r.final_ssthresh)
    @printf("mean RTT=%.3f ms\n", 1000 * r.mean_rtt_s)
    println("="^60)
    return r
end

"""
    demo_dtn()

Bundle store-and-forward over a ContactPlan (CGR + custody wait).
"""
function demo_dtn()
    println("="^60)
    println("SatelliteSimNetSim demo — Bundle / BPA store-and-forward")
    println("="^60)
    plan = ContactPlan()
    # early path gone; must wait for 1→4 then 4→3
    add_contact!(plan, 1, 4, 12.0, 20.0, 0.04)
    add_contact!(plan, 4, 3, 14.0, 22.0, 0.04)
    add_contact!(plan, 1, 3, 20.0, 30.0, 0.08)

    payload = Vector{UInt8}("hello-dtn")
    r = simulate_dtn_forward(plan, 1, 3, payload; t0=10.0)
    @printf("delivered=%s  t=%.3fs  path=%s  hops=%d  deferred=%d\n",
            string(r.delivered), r.delivery_time, string(Int.(r.path)), r.hops, r.deferred)

    # also dump a tiny pcap of the serialized bundle
    pcap_path = joinpath(tempdir(), "satellitesim_dtn_demo.pcap")
    pw = open_pcap(pcap_path)
    b = Bundle(BundleEID("dtn://1/bpa"), BundleEID("dtn://3/bpa"), payload)
    write_pcap_packet!(pw, serialize_bundle(b); t=r.delivery_time)
    close_pcap!(pw)
    @printf("pcap: %s  (%d packets)\n", pcap_path, pw.packet_count)
    println("="^60)
    return r
end

"""
    demo_ltp(; loss=0.2)

LTP red/green transfer with segment loss + red retransmission.
"""
function demo_ltp(; loss::Real=0.2, seed::Int=3)
    println("="^60)
    println("SatelliteSimNetSim demo — LTP red/green")
    println("="^60)
    data = rand(UInt8, 2500)
    r = simulate_ltp_transfer(
        data;
        red_bytes=1500,
        segment_size=400,
        prop_delay_s=0.04,
        rate_bps=5e6,
        loss=loss,
        seed=seed,
    )
    @printf("red delivered=%s  red_bytes=%d  green_rx/tx=%d/%d\n",
            string(r.delivered_red), r.red_bytes, r.green_bytes_rx, r.green_bytes_tx)
    @printf("segs=%d  rexmit=%d  drops=%d  duration=%.3fs\n",
            r.segments_sent, r.retransmits, r.drops, r.duration_s)
    println("="^60)
    return r
end

"""
    demo_dual_fidelity()

Analytical prop-only vs DES underload/overload on the same hop delays,
plus an M/D/1 theory check and ns-3 scenario export.
"""
function demo_dual_fidelity()
    println("="^60)
    println("SatelliteSimNetSim demo — dual fidelity + baselines")
    println("="^60)
    hop_ms = [10.5, 10.8, 11.2, 10.1, 10.9, 10.4, 10.0]
    df = compare_path_fidelity(hop_ms, 100e6; duration_s=0.4, seed=7)
    @printf("analytical prop     : %.3f ms\n", df.analytical_prop_ms)
    @printf("DES underload mean  : %.3f ms  drops=%d  aligned=%s\n",
            df.underload.mean_latency_ms, df.underload.n_dropped, string(df.aligned))
    @printf("DES overload mean   : %.3f ms  drop=%.2f%%  queue=%.3f ms\n",
            df.overload.mean_latency_ms, 100 * df.overload_drop_ratio, df.overload_queue_ms)

    md = compare_to_md1(10.0, 100e6; load_frac=0.7, duration_s=1.5, seed=1)
    @printf("M/D/1 ρ=%.2f  theory=%.3f ms  DES=%.3f ms  rel_err=%.1f%%  ok=%s\n",
            md.rho, 1000 * md.theory_wait_s, 1000 * md.des_queue_s,
            100 * md.rel_error, string(md.within_tol))

    sc_path = joinpath(tempdir(), "satellitesim_ns3_scenario.json")
    export_ns3_scenario(sc_path, Ns3Scenario(
        "demo_7hop_overload", hop_ms, 100e6, 1500, 130e6, 2.0, 32, 42,
    ))
    println("ns-3 scenario: ", sc_path)
    println("="^60)
    return (df, md)
end

"""
    demo_aqm()

Compare DropTail / RED / CoDel under the same overloaded multi-hop path.
"""
function demo_aqm(; load_mbps::Real=130.0, rate_mbps::Real=100.0, duration_s::Real=0.5, seed::Int=11)
    println("="^60)
    println("SatelliteSimNetSim demo — AQM compare (DropTail / RED / CoDel)")
    println("="^60)
    hop_ms = [10.5, 10.8, 11.2, 10.1, 10.9, 10.4, 10.0]
    results = Dict{Symbol,PathSimResult}()
    for kind in (:droptail, :red, :codel)
        r = simulate_path(
            hop_ms, rate_mbps * 1e6;
            load_bps=load_mbps * 1e6,
            duration_s=duration_s,
            poisson=true,
            seed=seed,
            max_packets=32,
            queue_kind=kind,
        )
        results[kind] = r
        @printf("%-8s  sent=%d deliv=%d drop=%.2f%%  mean_lat=%.3f ms  queue=%.3f ms\n",
                string(kind), r.n_sent, r.n_delivered, 100 * r.drop_ratio,
                r.mean_latency_ms, r.mean_queue_delay_ms)
    end
    println("="^60)
    return results
end

"""
    demo_tcp_cubic()

Simplified TCP CUBIC transfer demo.
"""
function demo_tcp_cubic(; rate_mbps::Real=10.0, total_bytes::Int=20_000)
    println("="^60)
    println("SatelliteSimNetSim demo — TCP CUBIC (simplified)")
    println("="^60)
    hop_ms = [20.0, 20.0]
    r = simulate_tcp_cubic(
        hop_ms,
        rate_mbps * 1e6;
        total_bytes=total_bytes,
        mss_bytes=1000,
        max_packets=8,
        rto_s=0.3,
        seed=7,
    )
    @printf("acked=%d / %d  segs=%d  rexmit=%d  drops=%d  completed=%s\n",
            r.bytes_acked, total_bytes, r.segments_sent, r.retransmits, r.drops, string(r.completed))
    @printf("duration=%.3fs  goodput=%.3f Mbps  cwnd=%d  w_max=%.1f\n",
            r.duration_s, r.goodput_bps / 1e6, r.final_cwnd, r.w_max)
    println("="^60)
    return r
end

# Standalone NetSim demo (no SatelliteSim* deps — pure DES)

using Printf: @printf

export demo_netsim

"""
    demo_netsim(; load_mbps=130.0, rate_mbps=100.0, duration_s=2.0)

Run a self-contained multi-hop DES demo with synthetic hop delays
(typical LEO ISL scale). Prints analytical vs DES metrics.
"""
function demo_netsim(;
    load_mbps::Real=130.0,
    rate_mbps::Real=100.0,
    duration_s::Real=2.0,
    seed::Int=42,
)
    # Synthetic 7-hop LEO path (~10–12 ms per hop → ~74 ms prop)
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

    println("-"^60)
    println("Analytical layer would only see:")
    @printf("  prop delay     : %.3f ms\n", result.prop_delay_ms)
    println("DES additionally reports:")
    @printf("  sent/deliv/drop: %d / %d / %d  (drop %.2f%%)\n",
            result.n_sent, result.n_delivered, result.n_dropped, 100 * result.drop_ratio)
    @printf("  e2e latency    : mean %.3f | p95 %.3f | max %.3f ms\n",
            result.mean_latency_ms, result.p95_latency_ms, result.max_latency_ms)
    @printf("  queue delay    : %.3f ms\n", result.mean_queue_delay_ms)
    @printf("  hop drops      : %s\n", string(result.hop_drops))
    println("="^60)
    return result
end

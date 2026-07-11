# Dual-fidelity comparison: analytical (prop-only) vs DES (queue/drop)

export DualFidelityResult, compare_path_fidelity
export Md1Baseline, md1_mean_wait_s, compare_to_md1
export Ns3Scenario, export_ns3_scenario

"""
    DualFidelityResult

Side-by-side metrics for the same multi-hop path under:
- **fast / analytical**: sum of per-hop propagation delays only
- **accurate / DES underload**: packet DES with load < capacity (queue ≈ 0)
- **accurate / DES overload**: packet DES with load > capacity (queue + drops)
"""
struct DualFidelityResult
    hop_prop_ms::Vector{Float64}
    analytical_prop_ms::Float64
    rate_bps::Float64
    underload::PathSimResult
    overload::PathSimResult
    underload_extra_ms::Float64   # mean_lat - prop (tx + residual queue)
    overload_queue_ms::Float64
    overload_drop_ratio::Float64
    aligned::Bool                 # underload mean latency ≈ prop (+ small tx)
end

"""
    compare_path_fidelity(hop_prop_ms, rate_bps; ...) -> DualFidelityResult

Run analytical + DES underload + DES overload on the same hop delays.
"""
function compare_path_fidelity(
    hop_prop_ms::AbstractVector{<:Real},
    rate_bps::Real;
    pkt_bytes::Int=1500,
    underload_frac::Real=0.5,
    overload_frac::Real=1.3,
    duration_s::Real=0.5,
    max_packets::Int=32,
    seed::Int=42,
    align_tol_ms::Real=5.0,
)
    hops_ms = Float64[Float64(x) for x in hop_prop_ms]
    isempty(hops_ms) && throw(ArgumentError("hop_prop_ms must be non-empty"))
    prop = sum(hops_ms)
    rate = Float64(rate_bps)

    under = simulate_path(
        hops_ms, rate;
        load_bps=underload_frac * rate,
        duration_s=duration_s,
        poisson=false,
        seed=seed,
        max_packets=max_packets,
        pkt_bytes=pkt_bytes,
    )
    over = simulate_path(
        hops_ms, rate;
        load_bps=overload_frac * rate,
        duration_s=duration_s,
        poisson=true,
        seed=seed,
        max_packets=max_packets,
        pkt_bytes=pkt_bytes,
    )

    tx_ms = length(hops_ms) * pkt_bytes * 8 / rate * 1000
    extra = under.mean_latency_ms - prop
    # Underload CBR: mean latency ≈ prop + per-hop transmission (no queue)
    aligned = under.n_dropped == 0 &&
              isfinite(under.mean_latency_ms) &&
              abs(under.mean_latency_ms - prop - tx_ms) <= align_tol_ms

    return DualFidelityResult(
        hops_ms, prop, rate, under, over,
        extra, over.mean_queue_delay_ms, over.drop_ratio, aligned,
    )
end

"""
    Md1Baseline

M/D/1 mean waiting time baseline for a single hop (theory vs DES).
"""
struct Md1Baseline
    lambda::Float64
    mu::Float64
    rho::Float64
    theory_wait_s::Float64
    des_queue_s::Float64
    rel_error::Float64
    within_tol::Bool
end

"""M/D/1 mean waiting time in queue (not including service): Wq = λ / (2μ(μ-λ))."""
function md1_mean_wait_s(λ::Real, μ::Real)
    λ = Float64(λ); μ = Float64(μ)
    λ <= 0 && return 0.0
    μ > λ || throw(ArgumentError("μ must exceed λ for stable M/D/1"))
    return λ / (2 * μ * (μ - λ))
end

"""
    compare_to_md1(prop_delay_ms, rate_bps; load_frac, ...) -> Md1Baseline

Single-hop DES vs M/D/1 theory (Poisson arrivals, deterministic service).
"""
function compare_to_md1(
    prop_delay_ms::Real,
    rate_bps::Real;
    load_frac::Real=0.7,
    pkt_bytes::Int=1500,
    duration_s::Real=2.0,
    max_packets::Int=10_000,
    seed::Int=1,
    rel_tol::Real=0.35,
)
    rate = Float64(rate_bps)
    μ = rate / (pkt_bytes * 8)          # packets / s
    λ = load_frac * μ
    theory = md1_mean_wait_s(λ, μ)
    r = simulate_path(
        [Float64(prop_delay_ms)], rate;
        load_bps=load_frac * rate,
        duration_s=duration_s,
        poisson=true,
        seed=seed,
        max_packets=max_packets,
        pkt_bytes=pkt_bytes,
    )
    des_q = max(r.mean_queue_delay_ms, 0.0) / 1000
    rel = theory == 0 ? (des_q == 0 ? 0.0 : Inf) : abs(des_q - theory) / theory
    return Md1Baseline(λ, μ, λ / μ, theory, des_q, rel, rel <= rel_tol)
end

"""
    Ns3Scenario

Portable description of a multi-hop path for external ns-3 comparison.
"""
struct Ns3Scenario
    name::String
    hop_prop_ms::Vector{Float64}
    rate_bps::Float64
    pkt_bytes::Int
    load_bps::Float64
    duration_s::Float64
    max_packets::Int
    seed::Int
end

function export_ns3_scenario(path::AbstractString, sc::Ns3Scenario)
    open(path, "w") do io
        println(io, "{")
        println(io, "  \"name\": \"$(sc.name)\",")
        println(io, "  \"simulator\": \"SatelliteSimNetSim\",")
        println(io, "  \"hop_prop_ms\": [$(join(string.(sc.hop_prop_ms), ", "))],")
        println(io, "  \"rate_bps\": $(sc.rate_bps),")
        println(io, "  \"pkt_bytes\": $(sc.pkt_bytes),")
        println(io, "  \"load_bps\": $(sc.load_bps),")
        println(io, "  \"duration_s\": $(sc.duration_s),")
        println(io, "  \"max_packets\": $(sc.max_packets),")
        println(io, "  \"seed\": $(sc.seed),")
        println(io, "  \"notes\": \"Compare DropTail multi-hop mean latency / drop ratio with ns-3 PointToPoint + DropTailQueue\"")
        println(io, "}")
    end
    return path
end

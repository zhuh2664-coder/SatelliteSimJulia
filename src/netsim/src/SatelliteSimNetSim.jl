"""
    SatelliteSimNetSim

Packet-level discrete-event network simulation for SatelliteSimJulia.

This package is the Phase-1 bridge between the analytical network layer
(`SatelliteSimNet` / AoN traffic) and ns-3-style fidelity:

- Reuses analytical ISL topology and per-hop propagation delays
- Adds queueing delay, drops, and latency distributions via ConcurrentSim
- Kept separate from the differentiable optimization path (DES is not AD-safe)

See `simulate_path` and `demo_netsim`.
"""
module SatelliteSimNetSim

using ConcurrentSim
using ResumableFunctions
using Random
using Statistics

include("core/packet.jl")
include("queue/queue.jl")
include("queue/drop_tail.jl")
include("des_path.jl")
include("bridge_analytical.jl")
include("demo.jl")

end # module

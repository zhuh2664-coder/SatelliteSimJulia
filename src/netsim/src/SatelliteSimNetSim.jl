"""
    SatelliteSimNetSim

Packet-level discrete-event network simulation for SatelliteSimJulia.

Phase 1: DropTail queues + multi-hop path DES (`simulate_path`)
Phase 2: ContactPlan / CGR, FlowMonitor, UDP helpers, simplified TCP Reno
Phase 3: Bundle/LTP, BPA store-and-forward, PCAP export

Kept separate from the differentiable optimization path (DES is not AD-safe).
"""
module SatelliteSimNetSim

using ConcurrentSim
using ResumableFunctions
using Random
using Statistics
using Printf: @printf

include("core/packet.jl")
include("queue/queue.jl")
include("queue/drop_tail.jl")
include("des_path.jl")
include("bridge_analytical.jl")
include("dtn/contact_plan.jl")
include("dtn/cgr.jl")
include("dtn/bundle.jl")
include("dtn/ltp.jl")
include("dtn/bpa.jl")
include("monitor/flow_monitor.jl")
include("monitor/pcap.jl")
include("transport/udp.jl")
include("transport/tcp_reno.jl")
include("demo.jl")

end # module

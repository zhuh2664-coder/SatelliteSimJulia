using ConcurrentSim, ResumableFunctions

mutable struct SatelliteConfig
    id::Int
    neighbors::Dict{Int, Float64}
    routing::Dict{Int, Int}
end

function build_satellite_network(configs::Vector{SatelliteConfig}, env)
    n = length(configs)
    nc = NodeContainer()
    Create(nc, n)
    nodes = [Get(nc, i) for i in 1:n]
    devices = Dict{Tuple{Int,Int}, Any}()
    channels = Dict{Tuple{Int,Int}, Any}()
    flow_mon = FlowMonitor()

    for cfg in configs
        for (nbr_id, delay) in cfg.neighbors
            key = (min(cfg.id, nbr_id), max(cfg.id, nbr_id))
            haskey(channels, key) && continue
            ch = PointToPointChannel(env, delay, 1e9)
            channels[key] = ch
            i_src = findfirst(c -> c.id == cfg.id, configs)
            i_dst = findfirst(c -> c.id == nbr_id, configs)
            dev_src = PointToPointDevice(UInt32(cfg.id), ch, env)
            dev_dst = PointToPointDevice(UInt32(nbr_id), ch, env)
            Attach(ch, dev_src); Attach(ch, dev_dst)
            AddDevice(nodes[i_src], dev_src)
            AddDevice(nodes[i_dst], dev_dst)
            devices[(cfg.id, nbr_id)] = dev_src
            devices[(nbr_id, cfg.id)] = dev_dst
        end
    end

    for cfg in configs
        routing = cfg.routing
        for (nbr_id, dev) in devices
            if nbr_id[1] == cfg.id
                SetRecvCallback(dev, (d, pkt, sender) -> begin
                    handle_packet(cfg.id, pkt, routing, devices, flow_mon)
                end)
            end
        end
    end
    return (nodes, devices, channels, flow_mon, nc)
end

function handle_packet(node_id, pkt, routing, devices, flow_mon)
    dst = pkt.dst
    now_t = Now()
    if dst == UInt32(node_id)
        delay = now_t - pkt.ts_create
        RecordRx(flow_mon, Ipv4Address(pkt.src), Ipv4Address(pkt.dst),
                 UInt16(1), UInt16(1), pkt.protocol,
                 pkt.size, now_t, delay)
    else
        next_hop = get(routing, Int(dst), nothing)
        if next_hop !== nothing
            out_dev = get(devices, (node_id, next_hop), nothing)
            out_dev !== nothing && Send(out_dev, pkt, nothing)
        end
    end
end

function run_packet_sim(sat_configs::Vector{SatelliteConfig},
                        traffic::Vector{Tuple{Int,Int,Float64,Int}};
                        duration::Float64=10.0)
    Initialize()
    env = GetEnv()
    nodes, devices, channels, flow_mon, nc = build_satellite_network(sat_configs, env)
    for (src_id, dst_id, interval, size) in traffic
        @process traffic_source(env, src_id, dst_id, interval, size, devices, flow_mon)
    end
    println("===== NetSim 包级仿真 ($(duration)s) =====")
    @time Run(duration)
    println("===== 结束 =====")
    return flow_mon
end

@resumable function traffic_source(env, src_id::Int, dst_id::Int,
                                    interval::Float64, size::Int,
                                    devices, flow_mon)
    out_dev = nothing
    for ((a, b), dev) in devices
        if a == src_id
            out_dev = dev; break
        end
    end
    out_dev === nothing && return
    while true
        @yield timeout(env, interval)
        pkt = Packet(next_pkt_id!(), size, UInt32(src_id), UInt32(dst_id), 17)
        pkt.ts_create = now(env)
        RecordTx(flow_mon, Ipv4Address(UInt32(src_id)),
                 Ipv4Address(UInt32(dst_id)),
                 UInt16(1), UInt16(1), UInt8(17), size, now(env))
        Send(out_dev, pkt, nothing)
    end
end

function run_traffic_matrix(sat_configs::Vector{SatelliteConfig},
                            pairs::Vector{Tuple{Int,Int}},
                            rate::Float64=1.0;
                            duration::Float64=10.0, pkt_size::Int=1024)
    Initialize()
    env = GetEnv()
    nodes, devices, channels, flow_mon, nc = build_satellite_network(sat_configs, env)
    for (src, dst) in pairs
        @process traffic_source(env, src, dst, rate, pkt_size, devices, flow_mon)
    end
    println("===== 流量矩阵 ($(length(pairs)) 条流, $(duration)s) =====")
    @time Run(duration)
    println("===== 结束 =====")
    return flow_mon
end

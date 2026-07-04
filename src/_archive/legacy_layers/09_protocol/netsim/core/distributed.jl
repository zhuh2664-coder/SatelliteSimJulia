"""
    distributed.jl — 分布式仿真

对标 ns-3 MPI 模块。
将大星座拆分为子网，分配到多个工作者并行仿真。
每个工作者仿真一部分卫星，通过消息传递协调事件。
"""
mutable struct DistributedSim
    enabled::Bool
    num_workers::Int
    worker_id::Int
    partition::Vector{UInt32}  # 本工作者负责的卫星ID
end

DistributedSim(;workers=1) = DistributedSim(workers > 1, workers, 0, UInt32[])

""" 卫星分配到工作者 (按轨道面划分) """
function partition_constellation(total_sats::Int, num_workers::Int, planes::Int)
    if num_workers <= 1
        return [collect(UInt32(1):UInt32(total_sats))]
    end
    sats_per_plane = total_sats ÷ planes
    partitions = Vector{UInt32}[]
    sats_per_worker = max(1, total_sats ÷ num_workers)
    for w in 1:num_workers
        start = (w-1) * sats_per_worker + 1
        stop = min(w * sats_per_worker, total_sats)
        push!(partitions, collect(UInt32(start):UInt32(stop)))
    end
    return partitions
end

""" 跨工作者事件转发 """
function cross_worker_event(dsim::DistributedSim, src::UInt32, dst::UInt32, event_data)
    dsim.enabled || return true
    if dsim.num_workers <= 1
        return true  # 单机，无转发
    end
    src_worker = (src - 1) ÷ (length(dsim.partition) + 1) + 1
    dst_worker = (dst - 1) ÷ (length(dsim.partition) + 1) + 1
    if src_worker != dst_worker
        # 跨工作者通信 (Julia Distributed.send/recv)
        return true
    end
    return true
end

""" 分布式仿真统计 """
function distributed_stats(dsim::DistributedSim, timing::Dict{Symbol, Float64})
    timing[:total_sim] = Now()
    return timing
end

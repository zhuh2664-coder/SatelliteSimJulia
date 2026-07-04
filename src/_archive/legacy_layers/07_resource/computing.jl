"""
    资源层 / 星载计算模块

    仿真卫星上的计算资源（任务卸载、处理延迟、任务队列）。
    使用 DataStructures.jl 的 PriorityQueue 管理任务队列。
"""

using DataStructures

export ComputeNode, ComputeTask, OffloadingPolicy,
       TaskQueue, process_tasks_local!, offload_tasks_greedy!,
       simulate_computing, total_compute_load

const DEFAULT_COMPUTE_FLOPS = 1e12      # 1 TFLOPS
const DEFAULT_MEMORY_GB = 64.0          # 64 GB 内存
const DEFAULT_BANDWIDTH_MBPS = 1000.0   # ISL带宽 (Mbps)

"""
    ComputeNode

星载计算节点。

# 字段
- `satellite_id::Int`: 卫星编号
- `compute_flops::Float64`: 计算能力 (FLOPS)
- `memory_gb::Float64`: 可用内存 (GB)
- `task_queue::Vector{Any}`: 待处理任务队列 (ComputeTask的Any容器)
- `processed::Int`: 已处理任务数
- `total_delay_s::Float64`: 累计处理延迟 (s)
"""
mutable struct ComputeNode
    satellite_id::Int
    compute_flops::Float64
    memory_gb::Float64
    task_queue::Vector{Any}
    processed::Int
    total_delay_s::Float64
end

function ComputeNode(sid::Int; flops::Float64 = DEFAULT_COMPUTE_FLOPS,
                     mem::Float64 = DEFAULT_MEMORY_GB)
    return ComputeNode(sid, flops, mem, Any[], 0, 0.0)
end

"""
    ComputeTask

计算任务。

# 字段
- `task_id::Int`: 任务ID
- `source_ground_id::Int`: 源地面站
- `flops_required::Float64`: 所需计算量 (FLOP)
- `data_size_mb::Float64`: 任务数据大小 (MB)
- `max_delay_s::Float64`: 最大允许延迟 (s)
- `arrival_time::Int`: 到达时间步
"""
struct ComputeTask
    task_id::Int
    source_ground_id::Int
    flops_required::Float64
    data_size_mb::Float64
    max_delay_s::Float64
    arrival_time::Int
end

"""
    OffloadingPolicy

任务卸载策略。
"""
abstract type OffloadingPolicy end

struct LocalOnly <: OffloadingPolicy end          # 仅在源卫星处理
struct GreedyOffload <: OffloadingPolicy end      # 卸载到最近空闲卫星
struct CapacityAware <: OffloadingPolicy end      # 考虑容量和延迟

"""
    process_tasks_local!(nodes::Vector{ComputeNode}, tasks::Vector{ComputeTask},
                        current_time::Int) -> (processed::Int, delay_s::Float64)

在本地卫星处理任务。
"""
function process_tasks_local!(nodes::Vector{ComputeNode},
                              tasks::Vector{ComputeTask},
                              current_time::Int)::Tuple{Int,Float64}
    processed = 0
    total_delay = 0.0
    for task in tasks
        node = nodes[task.source_ground_id]
        proc_time = task.flops_required / node.compute_flops
        if proc_time <= task.max_delay_s
            push!(node.task_queue, task)
            node.processed += 1
            node.total_delay_s += proc_time
            processed += 1
            total_delay += proc_time
        end
    end
    return processed, total_delay
end

"""
    offload_tasks_greedy!(nodes::Vector{ComputeNode}, tasks::Vector{ComputeTask},
                          isl_adjacency::Matrix{Float64}, current_time::Int)

贪心卸载：将任务卸载到最近的可用卫星。
"""
function offload_tasks_greedy!(nodes::Vector{ComputeNode},
                               tasks::Vector{ComputeTask},
                               isl_adjacency::Matrix{Float64},
                               current_time::Int)::Tuple{Int,Float64}
    n_sats = length(nodes)
    processed = 0
    total_delay = 0.0
    c = 299792.458  # km/s

    for task in tasks
        src = task.source_ground_id
        best_node = src
        best_delay = Inf

        for dst in 1:n_sats
            if isl_adjacency[src, dst] < Inf / 2
                tx_delay = isl_adjacency[src, dst] / c + 0.01  # 传播 + 处理开销
                proc_time = task.flops_required / nodes[dst].compute_flops
                total_time = tx_delay + proc_time
                if total_time < best_delay && total_time <= task.max_delay_s
                    best_delay = total_time
                    best_node = dst
                end
            end
        end

        if best_delay < Inf
            push!(nodes[best_node].task_queue, task)
            nodes[best_node].processed += 1
            nodes[best_node].total_delay_s += best_delay
            processed += 1
            total_delay += best_delay
        end
    end
    return processed, total_delay
end

"""
    simulate_computing(nodes, tasks, isl_adj, policy, current_time)
                   -> (success_rate, avg_delay_s)

运行计算仿真。
"""
function simulate_computing(nodes::Vector{ComputeNode},
                            tasks::Vector{ComputeTask},
                            isl_adj::Matrix{Float64},
                            policy::OffloadingPolicy,
                            current_time::Int)::Tuple{Float64,Float64}

    if isa(policy, LocalOnly)
        proc, delay = process_tasks_local!(nodes, tasks, current_time)
    else
        proc, delay = offload_tasks_greedy!(nodes, tasks, isl_adj, current_time)
    end

    total = length(tasks)
    rate = total > 0 ? proc / total : 0.0
    avg_d = proc > 0 ? delay / proc : 0.0
    return rate, avg_d
end

"""
    total_compute_load(nodes::Vector{ComputeNode}) -> Float64

累计计算负载 (TFLOPS)。
"""
function total_compute_load(nodes::Vector{ComputeNode})::Float64
    return sum(n.compute_flops for n in nodes) / 1e12
end

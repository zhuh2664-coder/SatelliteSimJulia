"""
    瓶颈检测模块

本文件是优化层与流量层之间的关键桥梁：
将 traffic_layer 产生的 TrafficEvaluation 转换为 CapacityOptimizationSnapshot，
并提供利用率计算与瓶颈检测，供 losses.jl / metrics.jl / optimizer.jl 使用。

# 利用率计算（Utilization Ratio）
#
# 利用率定义：u = load / (capacity + ε)
#
# 其中 ε ≈ 1e-9 是防止除零的小量。
# 当 capacity = 0 时，u ≈ load / ε，即极大的值，表示完全拥塞。
# 加 ε 而非直接判断 capacity == 0 的好处：
#   - 避免分支判断，保持函数光滑（有利于自动微分）
#   - 在优化过程中，容量可能被优化器调整到接近 0 的值，
#     ε 保证了梯度的数值稳定性

# 瓶颈检测算法
#
# 瓶颈判定条件：utilization >= threshold
#   - 默认阈值 threshold = 0.5（50% 利用率）
#   - 可按链路类型筛选（:gsl, :isl, 或全部）
#
# 为什么用 50% 而非 100% 作为阈值：
#   - 100% 利用率意味着已经完全拥塞，为时已晚
#   - 50% 阈值提供了预警空间，允许优化器在拥塞发生前介入
#   - 在流量工程中，通常认为利用率超过 70-80% 就需要关注
#
# 瓶颈链路是优化层的首要目标：
#   - 在 losses.jl 中，soft_congestion 对瓶颈链路施加惩罚
#   - 优化器通过调整 throttle 变量来降低瓶颈链路的负载
"""

"""
    utilization(snapshot::CapacityOptimizationSnapshot; eps::Real=1e-9) -> Float64

计算链路利用率 `load / (capacity + eps)`。

# 参数
- `snapshot::CapacityOptimizationSnapshot`：链路快照。
- `eps::Real`：防止除零的小量。

# 返回值
- `Float64`：链路利用率，若容量为 0 则近似为 load / eps。
"""
utilization(snapshot::CapacityOptimizationSnapshot; eps::Real = 1e-9)::Float64 =
    snapshot.load_mbps / (snapshot.capacity_mbps + Float64(eps))

"""
    bottleneck_snapshots(snapshots; threshold::Real=0.5, link_type::Union{Nothing,Symbol}=:gsl) -> Vector{CapacityOptimizationSnapshot}

从快照集合中筛选利用率超过阈值的瓶颈链路。

# 筛选逻辑
#   对每个 snapshot，检查两个条件：
#     1. 链路类型匹配（如果 link_type 不为 nothing）
#     2. utilization(snapshot) >= threshold
#   两个条件同时满足时，该 snapshot 被视为瓶颈。
#
# 时间复杂度：O(N)，N 为快照总数。
# 空间复杂度：O(K)，K 为瓶颈链路数量（通常远小于 N）。
#
# 典型使用场景：
#   - 识别需要扩容的 GSL 链路（地面站接入瓶颈）
#   - 识别需要分流的 ISL 链路（星间链路过载）
#   - 为优化器提供初始关注点（哪些链路最需要调整）

# 参数
- `snapshots::AbstractVector{CapacityOptimizationSnapshot}`：链路快照集合。
- `threshold::Real`：利用率阈值；必须非负。
- `link_type::Union{Nothing,Symbol}`：仅返回该类型链路；`nothing` 表示全部。

# 返回值
- `Vector{CapacityOptimizationSnapshot}`：瓶颈快照列表。
"""
function bottleneck_snapshots(
    snapshots::AbstractVector{CapacityOptimizationSnapshot};
    threshold::Real = 0.5,
    link_type::Union{Nothing,Symbol} = :gsl,
)::Vector{CapacityOptimizationSnapshot}
    threshold >= 0 || throw(ArgumentError("threshold must be non-negative"))
    if link_type !== nothing
        link_type in (:gsl, :isl) || throw(ArgumentError("link_type must be :gsl, :isl, or nothing"))
    end
    return [
        snapshot for snapshot in snapshots
        if (link_type === nothing || snapshot.link_type == link_type) &&
           utilization(snapshot) >= threshold
    ]
end

"""
    聚合指标模块

本文件提供基于 CapacityOptimizationSnapshot 的聚合指标：
统计链路中发生拥堵的比例，以及平均链路利用率。
这些指标常用于优化后的效果评估，不直接参与梯度计算。
"""

"""
    congested_ratio(snapshots; link_type=:gsl) -> Float64

计算快照集合中负载超过容量的链路比例（即拥堵率）。

# 参数
- `snapshots::AbstractVector{CapacityOptimizationSnapshot}`：链路容量快照集合。
- `link_type::Union{Nothing,Symbol}`：仅统计该类型的链路；`nothing` 表示全部类型。

# 返回值
- `Float64`：拥堵链路数占选中链路总数的比例；若选中为空则返回 0.0。

# 依赖
- 使用 `models.jl` 中定义的 `CapacityOptimizationSnapshot`。
"""
function congested_ratio(
    snapshots::AbstractVector{CapacityOptimizationSnapshot};
    link_type::Union{Nothing,Symbol} = :gsl,
)::Float64
    # 按链路类型过滤；link_type 为 nothing 时保留全部快照。
    selected = [
        snapshot for snapshot in snapshots
        if link_type === nothing || snapshot.link_type == link_type
    ]
    isempty(selected) && return 0.0
    # 严格拥堵判定：负载大于容量（不含等于）。
    congested = count(snapshot -> snapshot.load_mbps > snapshot.capacity_mbps, selected)
    return congested / length(selected)
end

"""
    average_utilization(snapshots; link_type=:gsl) -> Float64

计算快照集合的平均链路利用率。

# 参数
- `snapshots::AbstractVector{CapacityOptimizationSnapshot}`：链路容量快照集合。
- `link_type::Union{Nothing,Symbol}`：仅统计该类型的链路；`nothing` 表示全部类型。

# 返回值
- `Float64`：选中快照利用率的算术平均值；若选中为空则返回 0.0。

# 依赖
- 依赖 `bottleneck.jl` 中定义的 `utilization(::CapacityOptimizationSnapshot)`。
"""
function average_utilization(
    snapshots::AbstractVector{CapacityOptimizationSnapshot};
    link_type::Union{Nothing,Symbol} = :gsl,
)::Float64
    selected = [
        snapshot for snapshot in snapshots
        if link_type === nothing || snapshot.link_type == link_type
    ]
    isempty(selected) && return 0.0
    return sum(utilization(snapshot) for snapshot in selected) / length(selected)
end

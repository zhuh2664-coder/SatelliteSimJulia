"""
    优化层核心数据类型模块

本文件定义优化层使用的核心数据类型：
- `CapacityOptimizationSnapshot`：从 TrafficEvaluation 抽取的链路容量/负载快照，
  是 congestion_loss、bottleneck_snapshots 等可微损失与瓶颈分析的输入。
- `CapacityLossWeights`：多目标容量优化损失的权重容器。
"""

"""
    CapacityOptimizationSnapshot

链路容量优化快照。从流量评估结果中提取某一时刻、某条链路的负载与容量信息，
作为拥堵损失、瓶颈检测与可微优化的基础数据单元。

# 字段
- `time_index::Int`：在时间网格中的索引（从 1 开始）。
- `elapsed_s::Int`：相对于仿真起始时刻的经过秒数。
- `link_type::Symbol`：链路类型，仅允许 `:gsl`（地面-卫星）或 `:isl`（星间）。
- `link_id::Union{Nothing,Int}`：链路全局编号；无编号时可为 `nothing`。
- `endpoint_a_id::Int`：链路一端节点 ID。
- `endpoint_b_id::Int`：链路另一端节点 ID。
- `load_mbps::Float64`：链路上的业务负载（Mbps）。
- `capacity_mbps::Float64`：链路可用容量（Mbps）。
"""
struct CapacityOptimizationSnapshot
    time_index::Int
    elapsed_s::Int
    link_type::Symbol
    link_id::Union{Nothing,Int}
    endpoint_a_id::Int
    endpoint_b_id::Int
    load_mbps::Float64
    capacity_mbps::Float64

    function CapacityOptimizationSnapshot(;
        time_index::Int,
        elapsed_s::Int,
        link_type::Symbol,
        link_id::Union{Nothing,Int},
        endpoint_a_id::Int,
        endpoint_b_id::Int,
        load_mbps::Real,
        capacity_mbps::Real,
    )
        # 校验基本物理与索引约束，避免非法快照流入下游损失计算。
        time_index > 0 || throw(ArgumentError("time_index must be positive"))
        elapsed_s >= 0 || throw(ArgumentError("elapsed_s must be non-negative"))
        link_type in (:gsl, :isl) || throw(ArgumentError("link_type must be :gsl or :isl"))
        endpoint_a_id > 0 || throw(ArgumentError("endpoint_a_id must be positive"))
        endpoint_b_id > 0 || throw(ArgumentError("endpoint_b_id must be positive"))
        load_mbps >= 0 || throw(ArgumentError("load_mbps must be non-negative"))
        capacity_mbps >= 0 || throw(ArgumentError("capacity_mbps must be non-negative"))
        return new(
            time_index,
            elapsed_s,
            link_type,
            link_id,
            endpoint_a_id,
            endpoint_b_id,
            Float64(load_mbps),
            Float64(capacity_mbps),
        )
    end
end

"""
    CapacityLossWeights

容量优化多目标损失函数的权重配置。

# 字段
- `congestion::Float64`：拥堵损失权重。
- `throughput::Float64`：吞吐量奖励/惩罚权重。
- `energy::Float64`：能耗相关权重。
- `defense::Float64`：防御策略成本权重。
- `stealth::Float64`：攻击/策略隐蔽性权重。

所有权重必须非负。
"""
struct CapacityLossWeights
    congestion::Float64
    throughput::Float64
    energy::Float64
    defense::Float64
    stealth::Float64

    function CapacityLossWeights(;
        congestion::Real = 1.0,
        throughput::Real = 1.0,
        energy::Real = 0.0,
        defense::Real = 0.0,
        stealth::Real = 0.0,
    )
        # 确保各损失分量权重非负，避免优化方向出现矛盾。
        all(x -> x >= 0, (congestion, throughput, energy, defense, stealth)) ||
            throw(ArgumentError("loss weights must be non-negative"))
        return new(
            Float64(congestion),
            Float64(throughput),
            Float64(energy),
            Float64(defense),
            Float64(stealth),
        )
    end
end

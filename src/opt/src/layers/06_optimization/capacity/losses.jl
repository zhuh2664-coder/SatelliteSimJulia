"""
    可微损失函数模块

容量优化层的可微损失函数。
基于 CapacityOptimizationSnapshot 定义软拥堵损失与防御成本，
供 projected_gradient_descent 等优化器最小化。

# 损失函数设计原则
#
# 容量优化问题可以形式化为：
#   min  L(throttle) = L_congestion(throttle) + λ · L_defense(throttle)
#   s.t. 0 ≤ throttle_i ≤ 1  （调控变量在 [0,1] 范围内）
#
# 其中：
#   - throttle：调控变量，表示对每条链路/每个需求的流量缩放因子
#     throttle = 1 表示不干预（原始流量）
#     throttle = 0 表示完全阻断
#   - L_congestion：拥堵惩罚，鼓励减少过载链路的负载
#   - L_defense：防御成本，鼓励最小化调控动作（避免过度干预）
#   - λ：正则化系数，平衡拥堵惩罚与防御成本
#
# 这种形式类似于 Tikhonov 正则化（岭回归），在优化中广泛使用。
"""

"""
    soft_congestion(snapshot::CapacityOptimizationSnapshot; beta::Real=20.0) -> Float64

计算单条链路的软拥堵量：当利用率大于 1 时返回光滑正值，否则近似为 0。

# 软拥堵量计算
#   q = smooth_relu(u - 1.0)
#   其中 u = utilization = load / (capacity + ε)
#
# 数学性质：
#   - 当 u < 1（未过载）：q ≈ 0（smooth_relu 在负输入区域接近 0）
#   - 当 u = 1（刚好满载）：q = smooth_relu(0) = log(2)/β ≈ 0.035
#   - 当 u > 1（过载）：q ≈ u - 1（过载量，即负载超过容量的部分）
#
# 为什么用 smooth_relu 而非 max(0, u-1)：
#   - max(0, u-1) 在 u=1 处不可导（左导数=0，右导数=1）
#   - smooth_relu 在 u=1 处可导，梯度为 σ(0) = 0.5
#   - 这使得优化器可以在 u≈1 附近获得有意义的梯度信号

# 参数
- `snapshot::CapacityOptimizationSnapshot`：链路容量快照。
- `beta::Real`：smooth_relu 的温度系数。

# 返回值
- `Float64`：软拥堵量，始终非负且可微。
"""
function soft_congestion(snapshot::CapacityOptimizationSnapshot; beta::Real = 20.0)::Float64
    return smooth_relu(utilization(snapshot) - 1.0; beta = beta)
end

"""
    congestion_loss(snapshots; beta::Real=20.0, link_type::Union{Nothing,Symbol}=:gsl) -> Float64

计算所有快照的软拥堵损失平方和。

# 损失函数形式
#   L_congestion = Σ_i  q_i²
#   其中 q_i = soft_congestion(snapshot_i) 是第 i 条链路的软拥堵量。
#
# 为什么用平方和而非绝对值或简单求和：
#   1. 平方惩罚放大了严重拥堵的贡献：
#      - 如果 q_i = 0.1（轻微过载），q_i² = 0.01（小惩罚）
#      - 如果 q_i = 2.0（严重过载），q_i² = 4.0（大惩罚）
#      这鼓励优化器优先解决严重拥塞，而非均匀分配资源。
#   2. 平方函数处处可导（梯度 = 2q），比绝对值函数（在 0 处不可导）更适合梯度优化。
#   3. 这种形式等价于 L2 损失（MSE），在统计学和优化理论中有良好的性质。
#
# 可选的 link_type 筛选：
#   - :gsl：仅统计 GSL 链路拥堵（地面接入瓶颈）
#   - :isl：仅统计 ISL 链路拥堵（星间链路瓶颈）
#   - nothing：统计所有链路拥堵

# 参数
- `snapshots::AbstractVector{CapacityOptimizationSnapshot}`：链路快照集合。
- `beta::Real`：smooth_relu 温度系数。
- `link_type::Union{Nothing,Symbol}`：仅统计该类型链路；`nothing` 表示全部。

# 返回值
- `Float64`：拥堵损失总和。
"""
function congestion_loss(
    snapshots::AbstractVector{CapacityOptimizationSnapshot};
    beta::Real = 20.0,
    link_type::Union{Nothing,Symbol} = :gsl,
)::Float64
    total = 0.0
    for snapshot in snapshots
        if link_type === nothing || snapshot.link_type == link_type
            q = soft_congestion(snapshot; beta = beta)
            # 对软拥堵量取平方，放大高拥堵链路的惩罚。
            total += q * q
        end
    end
    return total
end

"""
    defense_cost(throttle::AbstractVector{<:Real}) -> Float64

防御/调控成本：鼓励 throttle 接近 1（即尽可能小的调控动作）。

# 正则化成本
#   L_defense = Σ_i (1 - s_i)²
#   其中 s_i 是第 i 个调控变量（throttle），s_i ∈ [0, 1]。
#
# 设计意图：
#   - 当 s_i = 1 时（不干预），(1-1)² = 0，无惩罚
#   - 当 s_i = 0 时（完全阻断），(1-0)² = 1，最大惩罚
#   - 当 s_i = 0.5 时（部分调控），(1-0.5)² = 0.25，中等惩罚
#
# 这种设计鼓励优化器尽可能保持原始流量分配（s_i ≈ 1），
# 只在必要时才进行调控（s_i < 1）。
#
# 与 L1 正则化的比较：
#   - L1 正则化 Σ|1-s_i|：倾向于产生稀疏解（大量 s_i = 1，少量 s_i = 0）
#   - L2 正则化 Σ(1-s_i)²：倾向于产生平滑解（s_i 接近 1 但不完全为 1）
#   - 本代码使用 L2 形式，因为调控动作应该是连续渐变的，而非突变的开关。
#
# 在总损失中的角色：
#   L_total = L_congestion + λ · L_defense
#   λ 是正则化系数，控制"解决拥堵"与"最小化干预"之间的权衡。
#   λ 越大，优化器越倾向于保持原始分配（即使有轻微拥堵）。
#   λ 越小，优化器越倾向于积极调控（即使干预成本很高）。

# 参数
- `throttle::AbstractVector{<:Real}`：各链路或各流量的调控变量，通常位于 [0, 1]。

# 返回值
- `Float64`：Σ(1 - s)²，表示调控偏离"不动作"状态的成本。
"""
function defense_cost(throttle::AbstractVector{<:Real})::Float64
    return sum((1.0 - Float64(s))^2 for s in throttle)
end

"""
    可微辅助函数模块

可微辅助函数集合。
这些函数将硬阈值（ReLU、阶跃、one-hot 选择）替换为光滑近似，
使容量优化损失能够通过自动微分或有限差分进行梯度估计。

# 为什么需要光滑近似？
#
# 原始的硬阈值函数（如 ReLU、阶跃函数）在阈值点处不可导（梯度为 0 或未定义）。
# 在基于梯度的优化中（如 projected gradient descent、Adam 等），
# 梯度信息是更新参数的唯一依据。如果损失函数处处梯度为零，优化器无法学习。
#
# 光滑近似的核心思想：
#   用一个处处可导的函数来近似硬阈值，同时保持在"远离阈值"处的渐近行为一致。
#   这样优化器可以在阈值附近获得有意义的梯度信号。

# 温度参数 β 的作用
#
# β（temperature parameter）控制光滑近似与原始硬函数的接近程度：
#   - β → ∞：光滑函数趋近于硬函数（精确近似，但梯度在阈值附近变得非常陡峭）
#   - β → 0：光滑函数趋近于线性（完全光滑，但近似误差大）
#   - β = 20（默认值）：在精度和数值稳定性之间取得平衡
#
# 实践中的权衡：
#   - β 太大：梯度在阈值附近爆炸（梯度 ~ β），可能导致数值不稳定
#   - β 太小：近似太粗糙，优化器看到的"拥堵"信号不准确
#   - β = 20 是经验值，在大多数场景下工作良好
"""

"""
    smooth_relu(x::Real; beta::Real=20.0) -> Real

光滑 ReLU（softplus）近似：f(x) = log(1 + exp(βx)) / β。

# 数学性质
#   原始 ReLU：f(x) = max(0, x)
#   Softplus：  f(x) = log(1 + exp(βx)) / β
#
#   当 x >> 0 时：f(x) ≈ x（与 ReLU 一致）
#   当 x << 0 时：f(x) ≈ 0（与 ReLU 一致）
#   当 x ≈ 0 时：f(x) ≈ (log(2)) / β ≈ 0.035（平滑过渡，而非硬拐点）
#
#   导数：f'(x) = σ(βx) = 1 / (1 + exp(-βx))
#   即 softplus 的导数是 sigmoid 函数，这在反向传播中非常有用。
#
# 在拥堵损失中的应用：
#   soft_congestion = smooth_relu(utilization - 1.0)
#   当 utilization > 1（过载）时，返回正值（拥堵量）
#   当 utilization ≤ 1（未过载）时，返回接近 0 的小值
#   梯度 ∂L/∂capacity 可以通过链式法则传播到容量参数。

# 参数
- `x::Real`：输入。
- `beta::Real`：温度系数；β 越大越接近硬 ReLU，但梯度越陡峭。

# 返回值
- 光滑且处处可微的 ReLU 近似值。
"""
smooth_relu(x::Real; beta::Real = 20.0) = log1p(exp(beta * x)) / beta

"""
    smooth_sigmoid(x::Real; beta::Real=20.0) -> Real

光滑 Sigmoid 近似阶跃函数。

# 数学性质
#   原始阶跃函数：H(x) = 1 if x > 0, else 0
#   Sigmoid 函数：σ(x) = 1 / (1 + exp(-βx))
#
#   当 x >> 0 时：σ(x) → 1
#   当 x << 0 时：σ(x) → 0
#   当 x = 0 时：σ(x) = 0.5
#
#   导数：σ'(x) = β · σ(x) · (1 - σ(x))
#   最大导数在 x = 0 处，值为 β/4
#
# 潜在应用（当前代码未直接使用，但为可微优化预留）：
#   - 光滑选择函数：用 softmax_weights 替代 argmax
#   - 光滑开关：在"启用/禁用"某个链路或策略之间平滑切换
#   - 概率建模：将硬决策软化为概率分布

# 参数
- `x::Real`：输入。
- `beta::Real`：温度系数；β 越大越接近 0-1 阶跃。

# 返回值
- 位于 (0, 1) 区间的光滑阶跃近似值。
"""
function smooth_sigmoid(x::Real; beta::Real = 20.0)
    z = beta * x
    return one(z) / (one(z) + exp(-z))
end

"""
    softmax_weights(theta::AbstractVector{<:Real}) -> Vector

对输入向量计算 softmax 权重，使其和为 1。

# 数学性质
#   Softmax 定义：w_i = exp(θ_i) / Σ_j exp(θ_j)
#
#   性质：
#     - w_i > 0 for all i
#     - Σ_i w_i = 1（构成概率分布）
#     - argmax(θ) = argmax(w)（保持排序不变）
#     - 当所有 θ_i 相等时，w_i = 1/n（均匀分布）
#
#   数值稳定性技巧（最大值平移）：
#     w_i = exp(θ_i - max(θ)) / Σ_j exp(θ_j - max(θ))
#     等价于原始 softmax，但避免了 exp(x) 在 x 很大时的上溢（overflow）。
#     例如 θ = [1000, 1001]，直接计算 exp(1001) 会溢出；
#     平移后 θ' = [-1, 0]，exp(0) = 1，数值安全。
#
# 潜在应用（为可微优化预留）：
#   - 替代 argmax 的可微选择
#   - 路由权重分配（多路径路由）
#   - 攻击策略的软选择

# 参数
- `theta::AbstractVector{<:Real}`：原始打分向量。

# 返回值
- 与 `theta` 同长度的概率分布向量；空输入返回空同类型向量。
"""
function softmax_weights(theta::AbstractVector{<:Real})
    isempty(theta) && return eltype(theta)[]
    # 数值稳定性：减去最大值，避免 exp 出现上溢。
    shifted = theta .- maximum(theta)
    weights = exp.(shifted)
    total = sum(weights)
    return weights ./ total
end

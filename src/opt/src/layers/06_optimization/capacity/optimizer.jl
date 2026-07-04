"""
    通用优化器模块

通用优化器实现。
当前使用有限差分估计梯度，并执行投影梯度下降（PGD），
使控制变量始终位于 [lower, upper] 区间内。注意：尚未与 SGP4/路由/流量主链路对接。
"""

"""
    finite_difference_gradient(objective, theta; step::Real=1e-5) -> Vector{Float64}

使用中心差分估计目标函数对参数向量 `theta` 的梯度。

# 参数
- `objective::Function`：接受参数向量并返回标量的目标函数。
- `theta::AbstractVector{<:Real}`：当前参数估计。
- `step::Real`：差分步长，必须为正。

# 返回值
- `Vector{Float64}`：梯度向量，第 i 分量为 (f(θ+δeᵢ) - f(θ-δeᵢ)) / (2δ)。

# 说明
- 时间复杂度 O(n) 次目标函数求值，n 为参数维度；高维场景应改用自动微分。
"""
function finite_difference_gradient(
    objective::Function,
    theta::AbstractVector{<:Real};
    step::Real = 1e-5,
)::Vector{Float64}
    step > 0 || throw(ArgumentError("step must be positive"))
    x = Float64.(theta)
    gradient = zeros(Float64, length(x))
    for i in eachindex(x)
        # 构造仅第 i 维变化 +/- step 的两个扰动向量。
        plus = copy(x)
        minus = copy(x)
        plus[i] += step
        minus[i] -= step
        # 中心差分公式，截断误差为 O(step²)。
        gradient[i] = (objective(plus) - objective(minus)) / (2 * step)
    end
    return gradient
end

"""
    projected_gradient_descent(objective, initial; learning_rate=0.05, iterations=100, lower=0.0, upper=1.0) -> Vector{Float64}

投影梯度下降优化器。在每次迭代中估计梯度，沿负梯度方向更新，
并通过 `clamp` 将参数投影回 [lower, upper] 区间。

# 参数
- `objective::Function`：待最小化的标量目标函数。
- `initial::AbstractVector{<:Real}`：初始参数。
- `learning_rate::Real`：学习率。
- `iterations::Int`：迭代次数。
- `lower::Real`：参数下界。
- `upper::Real`：参数上界。

# 返回值
- `Vector{Float64}`：优化后的参数向量。

# 依赖
- 调用本文件中的 `finite_difference_gradient` 计算梯度。
"""
function projected_gradient_descent(
    objective::Function,
    initial::AbstractVector{<:Real};
    learning_rate::Real = 0.05,
    iterations::Int = 100,
    lower::Real = 0.0,
    upper::Real = 1.0,
)::Vector{Float64}
    iterations >= 0 || throw(ArgumentError("iterations must be non-negative"))
    learning_rate > 0 || throw(ArgumentError("learning_rate must be positive"))
    lower <= upper || throw(ArgumentError("lower must be <= upper"))
    # 将初始参数投影到可行域，保证迭代始终从合法点开始。
    theta = clamp.(Float64.(initial), Float64(lower), Float64(upper))
    for _ in 1:iterations
        gradient = finite_difference_gradient(objective, theta)
        # 负梯度更新后再次投影，实现 box 约束。
        theta .= clamp.(theta .- Float64(learning_rate) .* gradient, Float64(lower), Float64(upper))
    end
    return theta
end

# =============================================================================
# Adam Optimizer with Enzyme Reverse-Mode AD
# =============================================================================
# 来源: DifferentiableLEO/src/optimize/adam.jl
# 使用 Enzyme.autodiff(Reverse) 计算梯度，Adam 更新参数。
# 验证速度: 28 ms/step for 24 satellites。
# =============================================================================

import Enzyme

"""
    AdamState

Mutable Adam optimizer state (Kingma & Ba, 2015).
"""
mutable struct AdamState
    m :: Vector{Float64}
    v :: Vector{Float64}
    t :: Int
end

AdamState(n::Int) = AdamState(zeros(n), zeros(n), 0)

"""
    adam_step!(state, grad, x; lr, β1, β2, ε) -> nothing

Apply one Adam update in-place.
"""
function adam_step!(
    state::AdamState,
    grad::Vector{Float64},
    x::Vector{Float64};
    lr::Float64 = 0.01,
    β1::Float64 = 0.9,
    β2::Float64 = 0.999,
    ε::Float64  = 1e-8,
)
    state.t += 1
    @. state.m = β1 * state.m + (1 - β1) * grad
    @. state.v = β2 * state.v + (1 - β2) * grad^2
    m̂ = @. state.m / (1 - β1^state.t)
    v̂ = @. state.v / (1 - β2^state.t)
    @. x -= lr * m̂ / (sqrt(v̂) + ε)
end

"""
    adam_optimize(loss_fn, x0; n_steps, lr, β1, β2, ε, callback) -> (x_opt, history)

Minimize loss_fn(x) using Adam with Enzyme reverse-mode gradients.
"""
function adam_optimize(
    loss_fn::Function,
    x0::Vector{Float64};
    n_steps::Int    = 600,
    lr::Float64     = 0.01,
    β1::Float64     = 0.9,
    β2::Float64     = 0.999,
    ε::Float64      = 1e-8,
    callback::Union{Function,Nothing} = nothing,
) :: Tuple{Vector{Float64}, Vector{Tuple{Int,Float64}}}
    x = copy(x0)
    n = length(x)
    state = AdamState(n)
    history = Tuple{Int,Float64}[]

    for step in 1:n_steps
        grad = _enzyme_gradient(loss_fn, x)
        loss_val = loss_fn(x)
        push!(history, (step, loss_val))

        callback !== nothing && callback(step, loss_val, x)

        adam_step!(state, grad, x; lr, β1, β2, ε)
    end

    return x, history
end

"""
    _enzyme_gradient(f, x) -> Vector{Float64}

Compute ∂f/∂x using Enzyme reverse-mode AD.
"""
function _enzyme_gradient(f::Function, x::Vector{Float64})
    dx = zeros(Float64, length(x))
    Enzyme.autodiff(
        Enzyme.set_runtime_activity(Enzyme.Reverse),
        Enzyme.Const(f),
        Enzyme.Active,
        Enzyme.Duplicated(x, dx),
    )
    return dx
end

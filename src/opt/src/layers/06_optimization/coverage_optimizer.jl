# ===== 覆盖率优化 driver（方案 D）=====
#
# 封装可微覆盖优化的统一入口：J2 传播 → 软覆盖 loss → Adam → 收敛报告
# 调研.md §7.5 推荐路径，基础设施已有（adam.jl + coverage.jl + propagator_j2_differentiable.jl）
# 本文件提供参数化 driver + 自动收敛判据

export ConvergenceReport, optimize_coverage

"""
    ConvergenceReport

覆盖优化的收敛报告，用于量化优化效果。

# 字段
- `initial_loss::Float64`: 初始 loss（优化前）
- `final_loss::Float64`: 最终 loss（优化后）
- `improvement_pct::Float64`: loss 下降百分比（正值=改善）
- `n_steps::Int`: 总优化步数
- `converged::Bool`: 是否收敛（loss 相对变化 < 1e-4 连续 10 步）
- `convergence_step::Int`: 达到收敛判据的步数（0=未收敛）
- `final_gradient_norm::Float64`: 最终梯度范数
- `loss_history::Vector{Tuple{Int,Float64}}`: loss 随步数曲线
"""
struct ConvergenceReport
    initial_loss::Float64
    final_loss::Float64
    improvement_pct::Float64
    n_steps::Int
    converged::Bool
    convergence_step::Int
    final_gradient_norm::Float64
    loss_history::Vector{Tuple{Int,Float64}}
end

"""
    optimize_coverage(loss_fn, x0; n_steps, lr, convergence_window, convergence_tol) -> (x_opt, report)

统一的覆盖优化 driver。

# 参数
- `loss_fn::Function`: 可微 loss 函数（接受参数向量，返回标量）
- `x0::Vector{Float64}`: 初始参数（如 RAAN/MA 向量）
- `n_steps::Int=300`: 最大优化步数
- `lr::Float64=1.0`: 学习率
- `convergence_window::Int=10`: 连续多少步变化 < tol 视为收敛
- `convergence_tol::Float64=1e-4`: 收敛阈值（相对变化）

# 返回
- `x_opt::Vector{Float64}`: 优化后的参数
- `report::ConvergenceReport`: 收敛报告

# 用法
```julia
using SatelliteSimOpt, ForwardDiff
# loss_fn 用 satellite_ecef_j2 + 软覆盖
loss = params -> begin
    pos = constellation_positions_j2(params, alt, inc, t)
    return -soft_coverage_score(pos, ground_grid)
end
x_opt, report = optimize_coverage(loss, x0; n_steps=500, lr=0.5)
println("覆盖率提升: \$(round(-report.improvement_pct, digits=1))%")
```
"""
function optimize_coverage(
    loss_fn::Function,
    x0::Vector{Float64};
    n_steps::Int = 300,
    lr::Float64 = 1.0,
    convergence_window::Int = 10,
    convergence_tol::Float64 = 1e-4,
)
    # 用现有 adam_optimize
    x_opt, history = adam_optimize(loss_fn, copy(x0); n_steps=n_steps, lr=lr)

    # 分析收敛性
    initial_loss = isempty(history) ? NaN : history[1][2]
    final_loss = isempty(history) ? NaN : history[end][2]
    improvement_pct = initial_loss != 0 ? (initial_loss - final_loss) / abs(initial_loss) * 100 : 0.0

    # 收敛步数：连续 convergence_window 步相对变化 < convergence_tol
    convergence_step = 0
    if length(history) >= convergence_window
        for i in convergence_window:length(history)
            window = [history[j][2] for j in (i-convergence_window+1):i]
            rel_changes = [abs(window[k+1]-window[k])/max(abs(window[k]),1e-10) for k in 1:length(window)-1]
            if all(rel_changes .< convergence_tol)
                convergence_step = i
                break
            end
        end
    end

    converged = convergence_step > 0

    # 最终梯度范数（用数值差分近似，避免 Enzyme 复杂度）
    final_grad_norm = NaN
    try
        # 用有限差分近似梯度范数
        ε = 1e-6
        f0 = loss_fn(x_opt)
        grad_approx = zeros(length(x_opt))
        for i in eachindex(x_opt)
            xp = copy(x_opt); xp[i] += ε
            grad_approx[i] = (loss_fn(xp) - f0) / ε
        end
        final_grad_norm = sqrt(sum(abs2, grad_approx))
    catch
        # 忽略
    end

    report = ConvergenceReport(
        initial_loss, final_loss, improvement_pct,
        n_steps, converged, convergence_step,
        final_grad_norm, history,
    )

    return x_opt, report
end

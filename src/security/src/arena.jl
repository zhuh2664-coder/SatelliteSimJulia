# ===== 对抗沙箱 Arena + 紫队闭环 =====
#
# 基于探索点 5 决策选 immutable：每轮 run_round 返回新 ArenaState，
# 历史完整可回放，利于 purple_loop 收敛分析。
#
# 集成探索点 4（AttackEffect）红队 + AnomalyThreshold 蓝队：
#   红队施加攻击 → 评估靶场指标 → 蓝队检测 → Verdict 仲裁
# 漏检时 purple_loop 自动生成新检测规则，部署回 Arena，重测收敛。

export Verdict, ArenaState, with_detector,
       run_round, purple_loop, summarize_history

"""
    Verdict

一轮对抗的仲裁结果。

# 字段
- `attack_summary::String`：攻击摘要（人类可读）
- `attack_succeeded::Bool`：攻击是否成功施加并产生影响
- `blue_detected::Bool`：蓝队是否检测到异常
- `blue_mitigated::Bool`：蓝队是否缓解（响应后指标恢复）
- `gap_description::String`：缺口描述（漏检时说明缺什么）
- `suggested_rule::Union{AnomalyThreshold,Nothing}`：漏检时建议新增的检测规则
- `metric_before::Float64`：攻击前关键指标值
- `metric_after::Float64`：攻击后关键指标值
"""
struct Verdict
    attack_summary::String
    attack_succeeded::Bool
    blue_detected::Bool
    blue_mitigated::Bool
    gap_description::String
    suggested_rule::Union{AnomalyThreshold,Nothing}
    metric_before::Float64
    metric_after::Float64
end

"""
    ArenaState

不可变对抗沙箱状态（探索点 5 候选 B）。

持有基线仿真结果（攻击前）、蓝队检测器集合、历史 Verdict。
每轮 run_round 返回新 ArenaState，历史可回放。

# 字段
- `baseline_result`：基线仿真结果（含 network/latency/routing_metrics 等字段）
- `detectors::Vector{AbstractDetector}`：蓝队检测器集合
- `history::Vector{Verdict}`：历史仲裁结果
- `key_metric::Symbol`：判定攻击成功/失败的关键指标（默认 :connectivity_ratio）
"""
struct ArenaState
    baseline_result::Any
    detectors::Vector{AbstractDetector}
    history::Vector{Verdict}
    key_metric::Symbol
end

"""
    ArenaState 构造器

# 参数
- `baseline_result`：基线仿真结果（ExperimentResult 或含同名字段的对象）
- `detectors`：初始蓝队检测器（Vector{AbstractDetector}，可用 AbstractDetector[] 起步）
- `key_metric`：关键指标，用于判定攻击是否成功（攻击导致该指标偏离基线即成功）
"""
function ArenaState(;
    baseline_result,
    detectors::Vector{<:AbstractDetector} = AbstractDetector[],
    key_metric::Symbol = :connectivity_ratio,
)
    # 统一转为 Vector{AbstractDetector}，兼容传入 Vector{AnomalyThreshold} 等具体子类型向量
    return ArenaState(baseline_result, AbstractDetector[d for d in detectors],
                      Verdict[], key_metric)
end

"""返回追加了检测器的 ArenaState 副本（紫队补规则用）。"""
function with_detector(state::ArenaState, d::AbstractDetector)::ArenaState
    ArenaState(state.baseline_result, vcat(state.detectors, [d]),
               state.history, state.key_metric)
end

"""返回追加了 Verdict 的 ArenaState 副本。"""
function with_verdict(state::ArenaState, v::Verdict)::ArenaState
    ArenaState(state.baseline_result, state.detectors,
               vcat(state.history, [v]), state.key_metric)
end

"""
    run_round(state, attack, attacked_result) -> (ArenaState, Verdict)

执行一轮对抗：给定攻击后的仿真结果，蓝队检测，仲裁判定。

# 参数
- `state::ArenaState`：当前沙箱状态
- `attack::AbstractAttack`：本轮攻击
- `attacked_result`：攻击施加后的仿真结果（调用方先用 attack! 改靶场再评估得到）

# 返回
`(新 ArenaState, Verdict)`。漏检时 Verdict.suggested_rule 自动生成，但**不自动部署**——
部署由 purple_loop 决策（见下）。
"""
function run_round(state::ArenaState, attack::AbstractAttack, attacked_result)::Tuple{ArenaState,Verdict}
    metric_before = extract_metric(state.baseline_result, state.key_metric)
    metric_after = extract_metric(attacked_result, state.key_metric)

    # 攻击成功判定：关键指标发生变化（偏离基线）
    attack_succeeded = metric_before !== nothing && metric_after !== nothing &&
                       metric_before != metric_after

    # 蓝队检测
    alarms = detect(state.detectors, attacked_result)
    blue_detected = !isempty(alarms)

    # 缺口判定：攻击成功但蓝队没检测到
    gap_description = ""
    suggested_rule::Union{AnomalyThreshold,Nothing} = nothing
    if attack_succeeded && !blue_detected && metric_before !== nothing && metric_after !== nothing
        deviation = abs(metric_after - metric_before)
        # 自动建议：基于观测到的偏离量生成检测器（阈值设为偏离的 50%，确保下次能检出）
        suggested_rule = AnomalyThreshold(
            metric = state.key_metric,
            baseline = metric_before,
            threshold = max(deviation * 0.5, 1e-9),
            direction = :both,
        )
        gap_description = "$(state.key_metric) 从 $(round(metric_before, digits=4)) 变到 $(round(metric_after, digits=4))，蓝队未检测"
    end

    v = Verdict(
        network_attack_summary(attack),
        attack_succeeded,
        blue_detected,
        false,  # 缓解判定需响应层，P1 暂不实现
        gap_description,
        suggested_rule,
        metric_before === nothing ? 0.0 : metric_before,
        metric_after === nothing ? 0.0 : metric_after,
    )
    return (with_verdict(state, v), v)
end

"""
    purple_loop(state, attacks, evaluate_fn; max_rounds=10) -> ArenaState

紫队自演化闭环：
  对每轮攻击，若漏检则自动部署 suggested_rule，重新检测，直到收敛或达上限。

# 参数
- `state::ArenaState`：初始沙箱
- `attacks::Vector{<:AbstractAttack}`：攻击池
- `evaluate_fn::Function`：(基线结果, 攻击) → 攻击后仿真结果

# 返回
最终 ArenaState，history 含每轮 Verdict，detectors 已被漏检补规则增厚。
"""
function purple_loop(state::ArenaState, attacks::Vector{<:AbstractAttack},
                     evaluate_fn::Function; max_rounds::Int = 10)::ArenaState
    for round in 1:max_rounds
        converged = true
        for attack in attacks
            attacked_result = evaluate_fn(state.baseline_result, attack)
            state, v = run_round(state, attack, attacked_result)
            # 漏检 → 自动部署建议规则
            if v.suggested_rule !== nothing
                state = with_detector(state, v.suggested_rule)
                converged = false
            end
        end
        converged && break  # 所有攻击都被检出，收敛
    end
    return state
end

"""
    summarize_history(state) -> String

汇总对抗历史，人类可读报告。
"""
function summarize_history(state::ArenaState)::String
    lines = String[]
    push!(lines, "紫队对抗历史（共 $(length(state.history)) 轮）：")
    push!(lines, "  最终检测器数: $(length(state.detectors))")
    n_succeeded = count(v -> v.attack_succeeded, state.history)
    n_detected = count(v -> v.blue_detected, state.history)
    n_gaps = count(v -> v.suggested_rule !== nothing, state.history)
    push!(lines, "  攻击成功: $n_succeeded / 检出: $n_detected / 漏检缺口: $n_gaps")
    for (i, v) in enumerate(state.history)
        status = v.attack_succeeded ? (v.blue_detected ? "✓检出" : "✗漏检") : "—无效"
        push!(lines, "  轮$i [$status] $(v.attack_summary)  $(state.key_metric) $(round(v.metric_before,digits=4))→$(round(v.metric_after,digits=4))")
    end
    join(lines, "\n")
end

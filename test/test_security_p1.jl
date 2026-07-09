# ===== 攻防对抗层 P1 端到端测试 =====
#
# 验证完整闭环：
#   真实仿真 → 基线结果 → attack! 施加 → 重新评估 → 蓝队检测 → Verdict → purple_loop 收敛
#
# 闭环数据流：
#   run_experiment 得 baseline_result
#   → assess_routing 拿基线距离矩阵 D
#   → attack!(D, LinkBlackhole) 破坏
#   → compute_network_metrics(D_attacked) 得攻击后 network 指标
#   → run_round(arena, attack, attacked_result) 蓝队检测 + 仲裁
#   → purple_loop 自演化（漏检补规则）

using Test
# Security 是显式选择的高级包；此端到端测试不依赖日常仿真伞包的隐式导出。
using SatelliteSimSecurity: AbstractDetector, LinkBlackhole, TopologySeverance, FaultScenario,
    attack!, compile_attack, apply_effect!, AttackEffect,
    AnomalyThreshold, Alarm, detect, extract_metric,
    Verdict, ArenaState, run_round, purple_loop, summarize_history,
    network_attack_summary

# ── 辅助：Floyd-Warshall 全对最短路径（把邻接矩阵转成可达距离矩阵）──
function floyd_warshall(adj::Matrix{Float64})::Matrix{Float64}
    D = copy(adj)
    n = size(D, 1)
    for k in 1:n, i in 1:n, j in 1:n
        if D[i, k] + D[k, j] < D[i, j]
            D[i, j] = D[i, k] + D[k, j]
        end
    end
    return D
end

# ── 辅助：从距离矩阵构造可检测的结果对象（含 connectivity_ratio）──
function metrics_from_D(D::Matrix{Float64})
    n = size(D, 1)
    finite_mask = isfinite.(D)
    finite_count = count(finite_mask) - n  # 排除对角线
    total_pairs = n * (n - 1)
    conn_ratio = finite_count / total_pairs
    non_diag = Float64[]
    for i in 1:n, j in 1:n
        if i != j && isfinite(D[i, j])
            push!(non_diag, D[i, j])
        end
    end
    avg_lat = isempty(non_diag) ? 0.0 : sum(non_diag) / length(non_diag)
    return (
        network = (connectivity_ratio = conn_ratio,),
        latency = (avg_latency_ms = avg_lat,),
    )
end

# 测试用：构造邻接 → Floyd-Warshall → metrics
function ring_baseline_metrics(n::Int)
    A = fill(Inf, n, n)
    for i in 1:n; A[i, i] = 0.0; end
    for i in 1:n
        j = mod1(i + 1, n)
        A[i, j] = 100.0; A[j, i] = 100.0
    end
    D = floyd_warshall(A)
    return D, metrics_from_D(D)
end

@testset "P1 红蓝对抗闭环" begin

    @testset "AttackEffect 中间表示" begin
        # LinkBlackhole 编译
        eff = compile_attack(LinkBlackhole(5))
        @test eff isa AttackEffect
        @test eff.isolate_sats == [5]
        @test isempty(eff.sever_edges)

        # TopologySeverance 编译
        eff2 = compile_attack(TopologySeverance([(1, 2), (3, 4)]))
        @test isempty(eff2.isolate_sats)
        @test length(eff2.sever_edges) == 2

        # FaultScenario 编译（复用）
        eff3 = compile_attack(FaultScenario("t", [7], [(8, 9)], 0, 10))
        @test eff3.isolate_sats == [7]
        @test eff3.sever_edges == [(8, 9)]
    end

    @testset "attack! 双通路一致性" begin
        # 单帧矩阵 vs 时序序列，施加同一攻击，结果应一致
        N = 10
        D_single = fill(Inf, N, N)
        for i in 1:N; D_single[i, i] = 0.0; end
        for i in 1:N
            j = mod1(i + 1, N)
            D_single[i, j] = 100.0; D_single[j, i] = 100.0
        end
        D_series = [copy(D_single) for _ in 1:3]

        atk = LinkBlackhole(4)
        apply_effect!(D_single, compile_attack(atk))
        apply_effect!(D_series, compile_attack(atk))

        # 单帧与序列每步结果一致
        @test all(D_series[t] == D_single for t in 1:3)
        @test all(isinf, D_single[4, :])
    end

    @testset "AnomalyThreshold 检测器" begin
        # 基线：连通性 1.0
        baseline_result = (network = (connectivity_ratio = 1.0,),)
        det = AnomalyThreshold(metric = :connectivity_ratio, baseline = 1.0, threshold = 0.05)

        # 正常（无偏离）→ 无告警
        @test detect(det, baseline_result) === nothing

        # 攻击后连通性降到 0.7 → 触发告警
        attacked = (network = (connectivity_ratio = 0.7,),)
        alarm = detect(det, attacked)
        @test alarm isa Alarm
        @test alarm.metric === :connectivity_ratio
        @test alarm.observed ≈ 0.7
        @test alarm.deviation ≈ -0.3
        @test alarm.severity === :critical  # 偏离 0.3 > 2×0.05

        # 边界：偏离小于阈值 → 不触发（严格大于）
        edge = (network = (connectivity_ratio = 0.96,),)  # 偏离 0.04 < 阈值 0.05
        @test detect(det, edge) === nothing

        # 校验
        @test_throws ArgumentError AnomalyThreshold(metric = :x, baseline = 1, threshold = -1)
        @test_throws ArgumentError AnomalyThreshold(metric = :x, baseline = 1, threshold = 1, direction = :bad)
    end

    @testset "端到端：攻击→检测→Verdict" begin
        # 24 星环：先建邻接 A，Floyd-Warshall 得基线可达矩阵 D
        N = 24
        A = fill(Inf, N, N)
        for i in 1:N; A[i, i] = 0.0; end
        for i in 1:N
            j = mod1(i + 1, N)
            A[i, j] = 100.0; A[j, i] = 100.0
        end
        D = floyd_warshall(A)
        baseline_metrics = metrics_from_D(D)
        @test baseline_metrics.network.connectivity_ratio ≈ 1.0  # 环全连通

        # Arena：基线 + 一个宽松检测器（阈值 0.5，连不通 50% 才告警）
        arena = ArenaState(
            baseline_result = baseline_metrics,
            detectors = [AnomalyThreshold(metric = :connectivity_ratio, baseline = 1.0, threshold = 0.5)],
            key_metric = :connectivity_ratio,
        )

        # 红队：隔离卫星 12。攻击改邻接 A，重算 Floyd 得攻击后可达矩阵
        atk = LinkBlackhole(12)
        A_attacked = copy(A)
        attack!(A_attacked, atk)
        D_attacked = floyd_warshall(A_attacked)
        attacked_metrics = metrics_from_D(D_attacked)
        # 隔离 1 颗星，该星到其他点不可达，连通性略降，但不到 0.5 阈值 → 漏检
        @test attacked_metrics.network.connectivity_ratio < 1.0

        # run_round：攻击成功但蓝队漏检（阈值太宽）
        arena2, v = run_round(arena, atk, attacked_metrics)
        @test v.attack_succeeded
        @test !v.blue_detected  # 阈值 0.5 太宽，漏检
        @test v.suggested_rule !== nothing  # 自动建议新规则
        @test occursin("未检测", v.gap_description)
    end

    @testset "purple_loop 自演化收敛" begin
        N = 24
        A = fill(Inf, N, N)
        for i in 1:N; A[i, i] = 0.0; end
        for i in 1:N
            j = mod1(i + 1, N)
            A[i, j] = 100.0; A[j, i] = 100.0
        end
        D = floyd_warshall(A)
        baseline_metrics = metrics_from_D(D)

        # Arena 初始无检测器 → 第一轮必然漏检 → 补规则 → 收敛
        arena = ArenaState(
            baseline_result = baseline_metrics,
            detectors = AbstractDetector[],  # 空！
            key_metric = :connectivity_ratio,
        )

        # 攻击池：隔离 3 颗不同的星
        attacks = [LinkBlackhole(5), LinkBlackhole(10), LinkBlackhole(15)]

        # evaluate_fn：基线 A + 攻击 → 邻接改 → Floyd → metrics
        function evaluate_fn(baseline, atk)
            A_attacked = copy(A)
            attack!(A_attacked, atk)
            return metrics_from_D(floyd_warshall(A_attacked))
        end

        final = purple_loop(arena, attacks, evaluate_fn; max_rounds = 5)

        # 验证：至少补了检测规则（初始空 → 应有规则）
        @test length(final.detectors) >= 1
        # 验证：历史记录了对抗过程
        @test length(final.history) >= 3  # 至少 3 次攻击各一轮
        # 验证：补的规则确实能检出（用最终检测器重测一个攻击）
        A_test = copy(A)
        attack!(A_test, LinkBlackhole(8))
        test_metrics = metrics_from_D(floyd_warshall(A_test))
        alarms = detect(final.detectors, test_metrics)
        @test !isempty(alarms)  # 收敛后应能检出

        # 打印报告（可视化收敛过程）
        report = summarize_history(final)
        @test occursin("紫队对抗历史", report)
    end

    @testset "TopologySeverance 攻击" begin
        N = 12
        A = fill(Inf, N, N)
        for i in 1:N; A[i, i] = 0.0; end
        for i in 1:N
            j = mod1(i + 1, N)
            A[i, j] = 100.0; A[j, i] = 100.0
        end
        baseline = metrics_from_D(floyd_warshall(A))

        # 切断环上的 2 条边，分裂为两个分量
        atk = TopologySeverance([(3, 4), (9, 10)])
        A_attacked = copy(A)
        attack!(A_attacked, atk)
        attacked = metrics_from_D(floyd_warshall(A_attacked))
        @test attacked.network.connectivity_ratio < baseline.network.connectivity_ratio

        # 严格检测器应触发
        det = AnomalyThreshold(metric = :connectivity_ratio, baseline = 1.0, threshold = 0.01)
        @test detect(det, attacked) !== nothing
    end
end

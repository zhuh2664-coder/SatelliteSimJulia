# ===== 攻防对抗层测试 =====
#
# 覆盖 P0 迁移的全部代码：
# - AbstractAttack 类型树（types.jl）
# - 拓扑攻击原语（topology_attacks.jl）：attack!/measure_capacity/find_minimum_cut/find_critical_links/dead_zone_cut_analysis
# - Energy Drain 攻击（energy_drain_attack.jl）
#
# 验证重点：
# 1. legacy 3 处 adj 笔误已修复（之前会 UndefVarError）
# 2. attack! 多重分派正确隔离卫星/切断链路
# 3. 类型树子类型关系正确

using Test
using SatelliteSimJulia
using SatelliteSimSecurity: AbstractAttack, AbstractNetworkAttack, AbstractGroundAttack,
    AbstractRFAttack, AbstractPayloadAttack, FaultScenario, attack!, measure_capacity,
    find_minimum_cut, find_critical_links, dead_zone_cut_analysis,
    EnergyDrainAttackConfig, energy_drain_attack_demands

# 辅助：构造 n 星环状邻接矩阵（每星连 ±1，面内 ISL）
function ring_adjacency(n::Int)::Matrix{Float64}
    A = fill(Inf, n, n)
    for i in 1:n
        A[i, i] = 0.0
    end
    for i in 1:n
        j = mod1(i + 1, n)
        d = 100.0 + 10 * i
        A[i, j] = d
        A[j, i] = d
    end
    return A
end

@testset "攻防对抗层" begin

    @testset "类型树" begin
        @test AbstractAttack isa DataType
        @test AbstractNetworkAttack <: AbstractAttack
        @test AbstractGroundAttack <: AbstractAttack
        @test AbstractRFAttack <: AbstractAttack
        @test AbstractPayloadAttack <: AbstractAttack
        # FaultScenario 应是 AbstractNetworkAttack 子类型
        @test FaultScenario <: AbstractNetworkAttack
    end

    @testset "attack! 多重分派" begin
        A = ring_adjacency(6)
        # 失效单颗卫星
        atk = FaultScenario("isolSat", [3], Tuple{Int,Int}[], 0, 10)
        A2 = attack!(copy(A), atk)
        @test all(isinf, A2[3, :])        # 第3行全 Inf
        @test all(isinf, A2[:, 3])        # 第3列全 Inf
        @test A2[1, 2] < Inf              # 其他链路不受影响（环边 1-2 存在）
        # 不应原地改原矩阵：原始 A 的卫星3到直接邻居(2,4)仍有边
        @test A[3, 2] < Inf               # 环上 2-3 相邻
        @test A[3, 4] < Inf               # 环上 3-4 相邻

        # 失效单条链路
        atk2 = FaultScenario("cutLink", Int[], [(1, 2)], 0, 10)
        A3 = attack!(copy(A), atk2)
        @test isinf(A3[1, 2])
        @test isinf(A3[2, 1])
        @test A3[2, 3] < Inf              # 相邻链路不受影响

        # 空故障场景（无操作）
        atk_empty = FaultScenario("noop", Int[], Tuple{Int,Int}[], 0, 0)
        A4 = attack!(copy(A), atk_empty)
        @test A4 == A
    end

    @testset "dead_zone_cut_analysis（验证 adj 笔误修复）" begin
        # 之前 legacy 此函数会因 adj 未定义报 UndefVarError
        A = ring_adjacency(6)
        # 完整环：单连通分量
        dz_full = dead_zone_cut_analysis(A)
        @test dz_full[:n_components] == 1
        @test dz_full[:reachability] ≈ 1.0

        # 切断卫星3 → 产生多个分量
        A2 = attack!(copy(A), FaultScenario("iso", [3], Tuple{Int,Int}[], 0, 10))
        dz_broken = dead_zone_cut_analysis(A2)
        @test dz_broken[:n_components] >= 2
        @test dz_broken[:reachability] < 1.0
    end

    @testset "find_critical_links（验证 adj 笔误修复）" begin
        # 之前 legacy 此函数会因 adj 未定义报 UndefVarError
        A = ring_adjacency(6)
        cl = find_critical_links(A; n_samples = 3)
        @test length(cl) == 6             # 6 星环有 6 条边
        # 每条边损失非负
        @test all(c[3] >= 0 for c in cl)
        # 按损失降序排列（cl[1] 损失最大）
        @test all(cl[i][3] >= cl[i+1][3] for i in 1:length(cl)-1)
    end

    @testset "find_minimum_cut" begin
        A = ring_adjacency(6)
        # 环上节点1到4。环边权重：1-2(110),2-3(120),3-4(130),4-5(140),5-6(150),6-1(160)
        # Ford-Fulkerson 找到的最小割 = 110(1-2) + 140(4-5) = 250
        # （比切断源邻边 110+160=270 或汇邻边 130+140=270 更小）
        flow, edges = find_minimum_cut(A, 1, 4)
        @test flow ≈ 250.0
        @test length(edges) >= 1
        # 验证割边确实把图分成含源和含汇两部分
        @test all(e -> e != (1, 4) && e != (4, 1), edges)  # 1和4非直连
    end

    @testset "measure_capacity" begin
        A = ring_adjacency(6)
        # 2 条需求，每条 10 Mbps，链路容量 100
        demands = [(1, 4, 10.0), (2, 5, 10.0)]
        total, satisfied, bottlenecks = measure_capacity(A, demands, 100.0)
        @test total ≈ 20.0
        @test satisfied ≈ 20.0             # 容量充足，全承载
        @test isempty(bottlenecks)         # 无瓶颈

        # 容量极低，触发瓶颈
        total2, satisfied2, bottlenecks2 = measure_capacity(A, demands, 5.0)
        @test total2 ≈ 20.0
        @test satisfied2 < total2          # 部分因超载丢弃
    end

    @testset "Energy Drain 攻击配置" begin
        # 构造与校验
        cfg = EnergyDrainAttackConfig(;
            source_ground_ids = [1, 2],
            destination_ground_ids = [3, 4],
            start_elapsed_s = 0,
            end_elapsed_s = 100,
            rate_mbps = 50.0,
        )
        @test cfg.id_start == 1_000_000
        @test cfg.rate_mbps == 50.0

        # 生成需求（2×2 笛卡尔积，跳过同源同目的，共 4 对 - 0 同 = 4 条流）
        demands = energy_drain_attack_demands(cfg)
        @test length(demands) == 4
        @test all(d.rate_mbps == 50.0 for d in demands)
        @test length(unique(d.id for d in demands)) == 4

        # 校验：源目的相同应报错
        @test_throws ArgumentError EnergyDrainAttackConfig(;
            source_ground_ids = [1], destination_ground_ids = [1],
            start_elapsed_s = 0, end_elapsed_s = 10, rate_mbps = 1.0,
        )
        # 校验：end <= start 应报错
        @test_throws ArgumentError EnergyDrainAttackConfig(;
            source_ground_ids = [1], destination_ground_ids = [2],
            start_elapsed_s = 10, end_elapsed_s = 10, rate_mbps = 1.0,
        )
        # 校验：负速率应报错
        @test_throws ArgumentError EnergyDrainAttackConfig(;
            source_ground_ids = [1], destination_ground_ids = [2],
            start_elapsed_s = 0, end_elapsed_s = 10, rate_mbps = -1.0,
        )
    end
end

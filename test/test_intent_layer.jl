# ===== 意图翻译层测试（防泄漏架构）=====
# 验证：用户/AI 传 TopologyIntent/RoutingIntent，平台正确翻译成具体策略。
# 实现名词（GridPlus/Dijkstra）只在 intent_resolution 内部出现，不泄漏到用户接口。

using Test
using SatelliteSimLab
using SatelliteSimCore: WalkerConstellationConfig
using SatelliteSimNet: GridPlusStrategy, RingStrategy, MeshStrategy,
    DijkstraRouting, ECMPRouting, MinLoadRouting

@testset "拓扑意图翻译" begin
    ctx_big = ResolutionContext(T=66, P=6)      # 大星座
    ctx_small = ResolutionContext(T=12, P=2)    # 小星座

    @test typeof(resolve_topology(BalancedTopo(), ctx_big)) == GridPlusStrategy
    @test typeof(resolve_topology(HighRobustTopo(), ctx_big)) == GridPlusStrategy
    @test typeof(resolve_topology(LowCostTopo(), ctx_big)) == RingStrategy

    # LowLatency：小星座用 Mesh，大星座用 GridPlus（Mesh 不可行）
    @test typeof(resolve_topology(LowLatencyTopo(), ctx_small)) == MeshStrategy
    @test typeof(resolve_topology(LowLatencyTopo(), ctx_big)) == GridPlusStrategy
end

@testset "路由意图翻译" begin
    ctx = ResolutionContext()
    @test typeof(resolve_routing(ShortestPath(), ctx)) == DijkstraRouting
    @test typeof(resolve_routing(LoadBalanced(), ctx)) == MinLoadRouting
    @test typeof(resolve_routing(MultipathIntent(), ctx)) == ECMPRouting
end

@testset "防泄漏：ExperimentConfig 接受意图" begin
    # 用户只传意图，代码里不出现任何 GridPlus/Dijkstra 名词
    cfg = ExperimentConfig(name="intent", topology_strategy=LowCostTopo(),
                           routing_algorithm=LoadBalanced())
    @test typeof(cfg.topology_strategy) == RingStrategy
    @test typeof(cfg.routing_algorithm) == MinLoadRouting
end

@testset "向后兼容：直传策略/符号仍可用" begin
    # 高级用户直接传策略
    cfg1 = ExperimentConfig(name="legacy1", topology_strategy=GridPlusStrategy(),
                            routing_algorithm=DijkstraRouting())
    @test typeof(cfg1.topology_strategy) == GridPlusStrategy
    @test typeof(cfg1.routing_algorithm) == DijkstraRouting

    # 旧符号（:ecmp 等）向后兼容
    cfg2 = ExperimentConfig(name="legacy2", routing_algorithm=:ecmp)
    @test typeof(cfg2.routing_algorithm) == ECMPRouting
end

@testset "默认值走翻译层" begin
    cfg = ExperimentConfig(name="default")
    # 默认 BalancedTopo → GridPlus，ShortestPath → Dijkstra
    @test typeof(cfg.topology_strategy) == GridPlusStrategy
    @test typeof(cfg.routing_algorithm) == DijkstraRouting
end

@testset "study DSL 接受意图" begin
    s = study("dsl_test"; topology=LowCostTopo(), routing=MultipathIntent())
    @test typeof(s.topology_strategy) == RingStrategy
    @test typeof(s.routing_algorithm) == ECMPRouting
end

@testset "goals 含 recommended_topology" begin
    # 所有 goal 都应有拓扑意图推荐
    for gid in list_goals()
        g = goal_info(gid)
        @test !isempty(g.recommended_topology)
        # 推荐值必须是合法意图符号
        for t in g.recommended_topology
            @test haskey(TOPLOGY_INTENTS, t)
        end
    end
    # 脆弱性分析应推荐高鲁棒
    @test :high_robust in goal_info(:vulnerability_analysis).recommended_topology
end

@testset "questionnaire 含拓扑意图问题" begin
    q = build_questionnaire(:routing_comparison)
    @test any(qn.id == :topology_intent for qn in q.questions)
    # 问题选项是意图符号，不是策略名
    topo_q = filter(qn -> qn.id == :topology_intent, q.questions)[1]
    @test :balanced in topo_q.options
    @test :low_latency in topo_q.options
    # 选项里绝不能出现 GridPlus/Honeycomb 这类实现名词
    @test !(:gridplus in topo_q.options || :honeycomb in topo_q.options)
end

println("✅ 意图翻译层测试全部通过（实现名词已隔离在防腐层）")

# ════════════════════════════════════════════════════════════
# 星座意图翻译（三正交维度组合）
# ════════════════════════════════════════════════════════════

@testset "星座意图：预设组合映射 catalog" begin
    # PolarCoverage + MidLatency + Medium → iridium
    intent = ConstellationIntent(coverage=PolarCoverage(), latency=MidLatencyConst(), scale=MediumScale())
    c = resolve_constellation_intent(intent)
    @test c.T == 66           # iridium
    @test c.inc_deg == 86.4
    @test c.alt_km == 780.0

    # GlobalCoverage + LowLatency + Large → starlink_gen1
    intent2 = ConstellationIntent(coverage=GlobalCoverage(), latency=LowLatencyConst(), scale=LargeScale())
    c2 = resolve_constellation_intent(intent2)
    @test c2.T == 1584        # starlink_gen1
    @test c2.alt_km == 550.0
end

@testset "星座意图：无预设时自动构造合法参数" begin
    # MidLatCoverage 没有预设，应自动构造
    intent = ConstellationIntent(coverage=MidLatCoverage(), latency=LowLatencyConst(), scale=SmallScale())
    c = resolve_constellation_intent(intent)
    @test c.inc_deg == 28.0   # 中低纬
    @test c.alt_km == 550.0   # 低时延
    @test c.T == 48           # 小规模
    @test c.P == 8
end

@testset "防泄漏：ExperimentConfig 接受星座意图" begin
    # 用户只传意图，不出现 :iridium/:walker48
    cfg = ExperimentConfig(name="t",
        constellation=ConstellationIntent(coverage=PolarCoverage(), latency=HighLatencyConst(), scale=LargeScale()))
    @test cfg.constellation.T == 648  # oneweb
end

@testset "星座意图向后兼容" begin
    # catalog 符号仍可用
    cfg1 = ExperimentConfig(name="leg1", constellation=:iridium)
    @test cfg1.constellation.T == 66
    # 直接 WalkerConfig 仍可用
    cfg2 = ExperimentConfig(name="leg2",
        constellation=WalkerConstellationConfig(T=10,P=2,F=1,alt_km=600.0,inc_deg=45.0))
    @test cfg2.constellation.T == 10
end

# ════════════════════════════════════════════════════════════
# 流量意图翻译
# ════════════════════════════════════════════════════════════

@testset "流量意图翻译" begin
    @test resolve_traffic_intent(UniformLoad()) == :uniform
    @test resolve_traffic_intent(HotspotLoad()) == :hotspot
    @test resolve_traffic_intent(VideoLoad())   == :video
    @test resolve_traffic_intent(IoTLoad())     == :iot
end

@testset "goals 含 recommended_constellation" begin
    for gid in list_goals()
        g = goal_info(gid)
        @test !isempty(g.recommended_constellation)
        # 每个推荐是三元组 (coverage, latency, scale) 符号
        for rec in g.recommended_constellation
            @test length(rec) == 3
            @test rec[1] in keys(COVERAGE_TARGETS)
            @test rec[2] in keys(LATENCY_TIERS)
            @test rec[3] in keys(CONSTELLATION_SCALES)
        end
    end
end

@testset "questionnaire 含星座三维度问题" begin
    q = build_questionnaire(:capacity_analysis)
    ids = [qn.id for qn in q.questions]
    @test :constellation_coverage in ids
    @test :constellation_latency in ids
    @test :constellation_scale in ids
    @test :traffic_intent in ids
end

println("✅ 星座/流量意图翻译测试全部通过（全层防泄漏完成）")

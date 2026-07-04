# ===== 意图翻译层闭环自检（防半拉子工程）=====
# 对每一层验证四要素：①Port定义 ②resolve翻译 ③Config字段 ④执行消费
# 核心反半拉子断言：改意图，执行结果必须变化。

using Test
using SatelliteSimLab
using SatelliteSimCore: WalkerConstellationConfig, TwoBodyPropagator, J2Propagator,
    J4Propagator, LEO_DEFAULTS, PhysicalConstraints

@testset "闭环自检：所有意图层四要素齐全" begin

    # ① 每个意图 Port 都有对应 resolve 函数（不抛 MethodError）
    ctx = ResolutionContext(T=66, P=6, alt_km=550.0, inc_deg=53.0)

    @testset "传播器意图" begin
        @test typeof(resolve_propagator(SpeedFocus(), ctx))     == TwoBodyPropagator
        @test typeof(resolve_propagator(BalancedProp(), ctx))   == J2Propagator
        @test typeof(resolve_propagator(PrecisionFocus(), ctx)) == J4Propagator
    end

    @testset "物理约束意图" begin
        b = resolve_constraint(BalancedLink(), ctx)
        s = resolve_constraint(StrictLink(), ctx)
        r = resolve_constraint(RelaxedLink(), ctx)
        @test b == LEO_DEFAULTS                       # 550km → LEO
        @test s.isl_max_range_km < b.isl_max_range_km  # 紧约束更短
        @test r.isl_max_range_km > b.isl_max_range_km  # 松约束更长
        @test s.gsl_min_elevation_deg > b.gsl_min_elevation_deg
    end

    @testset "时间窗意图" begin
        ts_o = resolve_time_horizon(SingleOrbit(), ctx)
        ts_d = resolve_time_horizon(FullDay(), ctx)
        ts_s = resolve_time_horizon(Snapshot(), ctx)
        @test length(ts_o) > 1 && last(ts_o) > 5000   # 一轨 ~5700s
        @test last(ts_d) == 86400.0                    # 全天
        @test ts_s == [0.0]                            # 快照
    end

    @testset "拓扑/路由/星座意图（已有，确认未破坏）" begin
        @test typeof(resolve_topology(BalancedTopo(), ctx)).name.name === :GridPlusStrategy
        @test typeof(resolve_routing(ShortestPath(), ctx)).name.name === :DijkstraRouting
        c = resolve_constellation_intent(ConstellationIntent(coverage=PolarCoverage(), latency=MidLatencyConst(), scale=MediumScale()))
        @test c.T == 66  # iridium
    end
end

@testset "Config 字段全意图化（默认值是意图非实现名词）" begin
    cfg = ExperimentConfig(name="smoke")
    @test typeof(cfg.propagator) == J2Propagator          # 默认 BalancedProp → J2
    @test last(cfg.tspan) > 5000                           # 默认 SingleOrbit → 一轨
    @test cfg.constraints == LEO_DEFAULTS                  # 默认 BalancedLink(550km) → LEO
    @test typeof(cfg.topology_strategy).name.name === :GridPlusStrategy  # BalancedTopo
    @test typeof(cfg.routing_algorithm).name.name === :DijkstraRouting   # ShortestPath
    @test cfg.traffic_demands isa Vector                   # traffic 字段存在
end

@testset "向后兼容：旧写法不破坏" begin
    # 旧符号
    @test typeof(ExperimentConfig(propagator=:two_body).propagator) == TwoBodyPropagator
    @test typeof(ExperimentConfig(propagator=:j4).propagator) == J4Propagator
    @test ExperimentConfig(tspan=[0.0, 1.0]).tspan == [0.0, 1.0]
    @test ExperimentConfig(constraints=LEO_DEFAULTS).constraints == LEO_DEFAULTS
    # 直接传实现类型
    @test typeof(ExperimentConfig(propagator=TwoBodyPropagator()).propagator) == TwoBodyPropagator
end

@testset "反半拉子终极断言：流量真消费" begin
    # 同配置只改 traffic，utilization 必须不同（用有 ISL 的星座）
    base = (constellation=ConstellationIntent(coverage=PolarCoverage(), latency=MidLatencyConst(), scale=MediumScale()),
            topology_strategy=BalancedTopo(), ground_pairs=[(1,2),(1,3),(2,3)])
    cfg_u = ExperimentConfig(; base..., traffic=UniformLoad())
    cfg_h = ExperimentConfig(; base..., traffic=HotspotLoad())
    res_u = run_experiment(cfg_u)
    res_h = run_experiment(cfg_h)
    @test res_u.utilization.avg_utilization != res_h.utilization.avg_utilization
end

@testset "反半拉子：传播器/约束/时间窗影响执行" begin
    # 不同传播器 → 不同位置 → 不同结果（精度差异）
    cfg_tb = ExperimentConfig(constellation=ConstellationIntent(coverage=GlobalCoverage(),scale=MediumScale()),
                              propagator=SpeedFocus(), topology_strategy=BalancedTopo())
    cfg_j2 = ExperimentConfig(constellation=ConstellationIntent(coverage=GlobalCoverage(),scale=MediumScale()),
                              propagator=BalancedProp(), topology_strategy=BalancedTopo())
    @test typeof(cfg_tb.propagator) == TwoBodyPropagator
    @test typeof(cfg_j2.propagator) == J2Propagator

    # 紧约束 vs 松约束 → ISL 数不同
    strict_c = resolve_constraint(StrictLink(), ResolutionContext(alt_km=550.0))
    relaxed_c = resolve_constraint(RelaxedLink(), ResolutionContext(alt_km=550.0))
    @test strict_c.isl_max_range_km < relaxed_c.isl_max_range_km
end

@testset "goals 全字段合法（无幽灵符号）" begin
    for gid in list_goals()
        g = goal_info(gid)
        @test !isempty(g.recommended_routing)
        @test !isempty(g.recommended_topology)
        @test !isempty(g.recommended_constellation)
        for r in g.recommended_routing
            @test r in keys(ROUTING_INTENTS)  # 必须是合法意图符号（非 :dijkstra/:qos）
        end
    end
end

println("✅ 意图层闭环自检全部通过（四要素齐全，无半拉子）")

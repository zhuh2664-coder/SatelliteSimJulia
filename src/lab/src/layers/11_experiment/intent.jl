# ===== 领域意图层（用户 / AI 唯一可见的配置接口）=====
#
# 防泄漏核心（调研 §13.A/C）：
#   用户只看到「意图」，看不到 GridPlus / Dijkstra 这类实现名词。
#   实现名词被关在 intent_resolution.jl（防腐层）内部。
#
# 设计：抽象类型作为 Port（六边形架构），新意图 = 新子类型。
# 翻译规则用多重分派实现（新意图 = 新方法，不改老的）。

export TopologyIntent, RoutingIntent,
       LowLatencyTopo, HighRobustTopo, BalancedTopo, LowCostTopo,
       ShortestPath, LoadBalanced, MultipathIntent,
       DefaultTopology, DefaultRouting,
       TOPLOGY_INTENTS, ROUTING_INTENTS, describe_intent,
       # 星座意图（三正交维度）
       CoverageTarget, GlobalCoverage, PolarCoverage, MidLatCoverage,
       LatencyTier, LowLatencyConst, MidLatencyConst, HighLatencyConst,
       ConstellationScale, SmallScale, MediumScale, LargeScale,
       ConstellationIntent, DefaultConstellation,
       COVERAGE_TARGETS, LATENCY_TIERS, CONSTELLATION_SCALES,
       # 流量意图
       TrafficIntent, UniformLoad, HotspotLoad, VideoLoad, IoTLoad,
       DefaultTraffic, TRAFFIC_INTENTS,
       # 传播器意图
       PropagatorIntent, SpeedFocus, BalancedProp, PrecisionFocus, TleBasedProp,
       DefaultPropagator, PROPAGATOR_INTENTS,
       # 物理约束意图
       ConstraintIntent, StrictLink, BalancedLink, RelaxedLink,
       DefaultConstraint, CONSTRAINT_INTENTS,
       # 时间窗意图
       TimeHorizonIntent, SingleOrbit, FullDay, Snapshot,
       DefaultTimeHorizon, TIME_HORIZON_INTENTS

# ────────────────────────────────────────────────────────────
# 拓扑意图（用户视角的工程目标，非拓扑学名词）
# ────────────────────────────────────────────────────────────

"""拓扑意图抽象（Port）。用户通过子类型表达工程目标，不接触具体拓扑策略。"""
abstract type TopologyIntent end

"""低时延：优先短路径/多连接（具体策略由 resolve_topology 按 ctx 决定）。"""
struct LowLatencyTopo <: TopologyIntent
    max_hops::Int
end
LowLatencyTopo() = LowLatencyTopo(8)

"""高鲁棒：最大化连通冗余，抗节点/链路失效。"""
struct HighRobustTopo <: TopologyIntent end

"""均衡：时延与成本的折衷（默认推荐）。"""
struct BalancedTopo <: TopologyIntent end

"""低成本：最小化 ISL 数量（每星更少激光终端）。"""
struct LowCostTopo <: TopologyIntent
    sat_cap::Int  # 星座规模上限，影响策略选择
end
LowCostTopo() = LowCostTopo(200)

# ────────────────────────────────────────────────────────────
# 路由意图
# ────────────────────────────────────────────────────────────

"""路由意图抽象（Port）。"""
abstract type RoutingIntent end

"""最短路径：最低时延基线（默认）。"""
struct ShortestPath <: RoutingIntent end

"""负载均衡：避免热点链路过载。"""
struct LoadBalanced <: RoutingIntent end

"""多路径：K 条等价路径分散流量，提升吞吐与鲁棒性。"""
struct MultipathIntent <: RoutingIntent
    k::Int
end
MultipathIntent() = MultipathIntent(3)

# ────────────────────────────────────────────────────────────
# 默认值（用户不指定时的合理默认）
# ────────────────────────────────────────────────────────────

const DefaultTopology = BalancedTopo()
const DefaultRouting  = ShortestPath()

# ────────────────────────────────────────────────────────────
# 意图目录（供 AI / questionnaire 列举）
# ────────────────────────────────────────────────────────────

"""所有可用拓扑意图（Symbol => 构造器）。"""
const TOPLOGY_INTENTS = IdDict(
    :low_latency => LowLatencyTopo,
    :high_robust => HighRobustTopo,
    :balanced    => BalancedTopo,
    :low_cost    => LowCostTopo,
)

"""所有可用路由意图。"""
const ROUTING_INTENTS = IdDict(
    :shortest_path  => ShortestPath,
    :load_balanced  => LoadBalanced,
    :multipath      => MultipathIntent,
)

describe_intent(s::Symbol) = haskey(TOPLOGY_INTENTS, s) ? "$(TOPLOGY_INTENTS[s])" :
                             haskey(ROUTING_INTENTS, s) ? "$(ROUTING_INTENTS[s])" :
                             haskey(COVERAGE_TARGETS, s) ? "$(COVERAGE_TARGETS[s])" :
                             haskey(LATENCY_TIERS, s) ? "$(LATENCY_TIERS[s])" :
                             haskey(CONSTELLATION_SCALES, s) ? "$(CONSTELLATION_SCALES[s])" :
                             haskey(TRAFFIC_INTENTS, s) ? "$(TRAFFIC_INTENTS[s])" : "unknown"

# ════════════════════════════════════════════════════════════
# 星座意图（三个正交维度组合）
# ════════════════════════════════════════════════════════════

# ── 维度 1：覆盖目标（决定倾角）──
"""覆盖目标抽象。决定星座倾角，从而决定地理覆盖范围。"""
abstract type CoverageTarget end

"""全球覆盖：倾斜中倾角 53°，覆盖到中高纬度（Starlink 类）。"""
struct GlobalCoverage  <: CoverageTarget end

"""极地覆盖：极轨 86.4°，聚焦高纬/极地（Iridium 类）。"""
struct PolarCoverage   <: CoverageTarget end

"""中低纬覆盖：低倾角 28°，密集覆盖中低纬（赤道区域）。"""
struct MidLatCoverage  <: CoverageTarget end

# ── 维度 2：时延层级（决定高度）──
"""时延层级抽象。决定轨道高度，从而决定单跳时延。"""
abstract type LatencyTier end

"""低时延：550km（Starlink 主壳，最低时延）。"""
struct LowLatencyConst   <: LatencyTier end

"""中时延：780-1000km（Iridium/Telesat）。"""
struct MidLatencyConst   <: LatencyTier end

"""高时延：1200km+（OneWeb，覆盖换时延）。"""
struct HighLatencyConst  <: LatencyTier end

# ── 维度 3：规模（决定 T/P）──
"""星座规模抽象。决定卫星总数与轨道面数。"""
abstract type ConstellationScale end

"""小规模：T=24-48（实验/快速验证）。"""
struct SmallScale   <: ConstellationScale end

"""中规模：T=66-120（原型/教学）。"""
struct MediumScale  <: ConstellationScale end

"""大规模：T=600+（真实星座复现）。"""
struct LargeScale   <: ConstellationScale end

# ── 组合意图 ──

"""
    ConstellationIntent

三个正交维度的组合，完整描述用户对星座的工程意图。
翻译层会按组合查预设 catalog，或自动构造 Walker 参数。
"""
Base.@kwdef struct ConstellationIntent
    coverage::CoverageTarget = GlobalCoverage()
    latency::LatencyTier = LowLatencyConst()
    scale::ConstellationScale = MediumScale()
end

"""默认星座意图（全球+低时延+中规模）。"""
const DefaultConstellation = ConstellationIntent()

# ── 维度目录（供 questionnaire）──
const COVERAGE_TARGETS = IdDict(
    :global  => GlobalCoverage,
    :polar   => PolarCoverage,
    :midlat  => MidLatCoverage,
)
const LATENCY_TIERS = IdDict(
    :low_latency  => LowLatencyConst,
    :mid_latency  => MidLatencyConst,
    :high_latency => HighLatencyConst,
)
const CONSTELLATION_SCALES = IdDict(
    :small  => SmallScale,
    :medium => MediumScale,
    :large  => LargeScale,
)

# ════════════════════════════════════════════════════════════
# 流量意图
# ════════════════════════════════════════════════════════════

"""流量意图抽象（Port）。用户表达业务场景，不接触流量模型实现细节。"""
abstract type TrafficIntent end

"""均匀负载：所有节点流量相同（基线对比）。"""
struct UniformLoad  <: TrafficIntent end

"""热点负载：少数节点产生大部分流量（城市/事件场景）。"""
struct HotspotLoad  <: TrafficIntent end

"""视频负载：大下行、小上行（流媒体分发）。"""
struct VideoLoad    <: TrafficIntent end

"""物联网负载：小包、低频、海量连接（传感器网络）。"""
struct IoTLoad      <: TrafficIntent end

"""默认流量意图（均匀基线）。"""
const DefaultTraffic = UniformLoad()

const TRAFFIC_INTENTS = IdDict(
    :uniform  => UniformLoad,
    :hotspot  => HotspotLoad,
    :video    => VideoLoad,
    :iot      => IoTLoad,
)

# ════════════════════════════════════════════════════════════
# 传播器意图（防泄漏：不暴露 TwoBody/J2/J4/SGP4）
# ════════════════════════════════════════════════════════════

"""传播器意图抽象（Port）。用户表达精度/速度权衡，不接触动力学模型名词。"""
abstract type PropagatorIntent end

"""速度优先：纯二体，最快但忽略所有摄动（大规模扫描/概念验证）。"""
struct SpeedFocus     <: PropagatorIntent end

"""均衡（默认）：J2 带谐项摄动，业界 LEO 仿真事实标准。"""
struct BalancedProp   <: PropagatorIntent end

"""精度优先：J4 高阶带谐项，Walker 流程内最高精度。"""
struct PrecisionFocus <: PropagatorIntent end

"""TLE/SGP4 精确传播：基于真实 TLE 与历元，走独立实验路径（非 Keplerian 家族）。"""
struct TleBasedProp <: PropagatorIntent end

const DefaultPropagator = BalancedProp()

const PROPAGATOR_INTENTS = IdDict(
    :speed_focus     => SpeedFocus,
    :balanced        => BalancedProp,
    :precision_focus => PrecisionFocus,
    :tle_based       => TleBasedProp,
)

# ════════════════════════════════════════════════════════════
# 物理约束意图（防泄漏：不暴露 LEO_DEFAULTS/MEO_DEFAULTS）
# ════════════════════════════════════════════════════════════

"""物理约束意图抽象（Port）。用户表达链路严格程度，不接触轨道类型预设名词。"""
abstract type ConstraintIntent end

"""紧约束：短 ISL 距离、高 GSL 仰角门限（保守设计，链路质量优先）。"""
struct StrictLink   <: ConstraintIntent end

"""均衡（默认）：按轨道高度自动选 LEO/MEO/GEO 预设。"""
struct BalancedLink <: ConstraintIntent end

"""松约束：长 ISL 距离、低仰角（激进设计，连通性优先）。"""
struct RelaxedLink  <: ConstraintIntent end

const DefaultConstraint = BalancedLink()

const CONSTRAINT_INTENTS = IdDict(
    :strict   => StrictLink,
    :relaxed  => RelaxedLink,
    :balanced => BalancedLink,
)

# ════════════════════════════════════════════════════════════
# 时间窗意图（防泄漏：不暴露裸 tspan 向量）
# ════════════════════════════════════════════════════════════

"""时间窗意图抽象（Port）。用户表达仿真时间尺度，不接触裸采样点向量。"""
abstract type TimeHorizonIntent end

"""单轨道：仿真一整个轨道周期（550km≈5740s），看完整覆盖循环。"""
struct SingleOrbit <: TimeHorizonIntent end

"""全天：仿真 24 小时（86400s），看长期演化/多圈覆盖。"""
struct FullDay     <: TimeHorizonIntent end

"""快照：单时刻（tspan=[0.0]），最快，只看瞬时拓扑。"""
struct Snapshot    <: TimeHorizonIntent end

const DefaultTimeHorizon = SingleOrbit()

const TIME_HORIZON_INTENTS = IdDict(
    :single_orbit => SingleOrbit,
    :full_day     => FullDay,
    :snapshot     => Snapshot,
)

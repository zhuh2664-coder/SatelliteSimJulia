# ===== 意图 → 具体实现（防腐层 / Anti-Corruption Layer）=====
#
# 这是防泄漏的关键（调研 §13.B/C）：
#   实现名词（GridPlusStrategy / DijkstraRouting）只在本文件内部出现，
#   永不泄漏到用户接口。
#
# 翻译模式 B1（调研 §13.B）：确定性规则表，可单测、可复现、零运行成本。
# 多重分派：新增意图 = 新增方法，不改现有翻译。
#
# 依赖方向：lab → net（合法，net 是工具层）。本文件 import net 的具体类型，
# 但 intent.jl 不 import——这就是 Port/Adapter 分离。

using SatelliteSimNet: AbstractTopologyStrategy, AbstractRoutingAlgorithm,
    GridPlusStrategy, HoneycombStrategy, RingStrategy, MeshStrategy, SpiralStrategy,
    DijkstraRouting, ECMPRouting, MinLoadRouting

using SatelliteSimCore: WalkerConstellationConfig, resolve_constellation,
    TwoBodyPropagator, J2Propagator, J4Propagator, AbstractKeplerianPropagator,
    PhysicalConstraints, LEO_DEFAULTS

# intent.jl 被 include 进 SatelliteSimLab，符号在同模块命名空间，直接引用
using ..SatelliteSimLab: TopologyIntent, RoutingIntent,
    LowLatencyTopo, HighRobustTopo, BalancedTopo, LowCostTopo,
    ShortestPath, LoadBalanced, MultipathIntent,
    CoverageTarget, GlobalCoverage, PolarCoverage, MidLatCoverage,
    LatencyTier, LowLatencyConst, MidLatencyConst, HighLatencyConst,
    ConstellationScale, SmallScale, MediumScale, LargeScale,
    ConstellationIntent, TrafficIntent,
    UniformLoad, HotspotLoad, VideoLoad, IoTLoad,
    PropagatorIntent, SpeedFocus, BalancedProp, PrecisionFocus,
    ConstraintIntent, StrictLink, BalancedLink, RelaxedLink,
    TimeHorizonIntent, SingleOrbit, FullDay, Snapshot

export ResolutionContext, resolve_topology, resolve_routing,
       resolve, supports_direct_strategy,
       resolve_constellation_intent, resolve_traffic_intent,
       lookup_constellation_preset,
       resolve_propagator, resolve_constraint, resolve_time_horizon,
       TrafficResolutionContext

"""
    ResolutionContext

意图翻译的上下文。携带「星座规模」等决策所需信息。
不同意图会按 ctx 选择不同的具体策略（如大星座不用 Mesh）。
"""
Base.@kwdef struct ResolutionContext
    T::Int = 0          # 卫星总数；0 表示未知，按保守默认
    P::Int = 0          # 轨道面数
    alt_km::Float64 = 550.0
    inc_deg::Float64 = 53.0   # 倾角（极轨 86.4° vs 倾斜 53° 影响约束）
end

# ────────────────────────────────────────────────────────────
# 拓扑意图翻译（规则表）
# ────────────────────────────────────────────────────────────

"""
    resolve_topology(intent, ctx) -> AbstractTopologyStrategy

把拓扑意图翻译成具体拓扑策略。实现名词被关在此处。
"""
function resolve_topology(intent::TopologyIntent, ctx::ResolutionContext=ResolutionContext())
    return _resolve_topo(intent, ctx)
end

# 低时延：小星座（≤30）用 Mesh 全互联降跳数；大星座用 GridPlus（Mesh 不可行）
_resolve_topo(::LowLatencyTopo, ctx) = ctx.T in 1:30 ? MeshStrategy() : GridPlusStrategy()

# 高鲁棒：4 度 GridPlus 提供冗余路径 + 较高 Fiedler 值
_resolve_topo(::HighRobustTopo, ctx) = GridPlusStrategy()

# 均衡：GridPlus 是业界事实标准，时延/成本/鲁棒性折衷
_resolve_topo(::BalancedTopo, ctx) = GridPlusStrategy()

# 低成本：Ring 度 2，每星仅 2 个激光终端，ISL 数最少
_resolve_topo(::LowCostTopo, ctx) = RingStrategy()

# ────────────────────────────────────────────────────────────
# 路由意图翻译
# ────────────────────────────────────────────────────────────

"""
    resolve_routing(intent, ctx) -> AbstractRoutingAlgorithm

把路由意图翻译成具体路由算法。实现名词被关在此处。
"""
resolve_routing(::ShortestPath, ctx) = DijkstraRouting()
resolve_routing(::LoadBalanced, ctx) = MinLoadRouting()
resolve_routing(m::MultipathIntent, ctx) = ECMPRouting()

# ────────────────────────────────────────────────────────────
# 统一入口（一次解析拓扑+路由）
# ────────────────────────────────────────────────────────────

"""
    resolve(; topology, routing, ctx) -> (topology_strategy, routing_algorithm)

统一翻译入口。接受意图或直接策略（向后兼容）。
"""
function resolve(;
    topology = DefaultTopology,
    routing = DefaultRouting,
    ctx::ResolutionContext = ResolutionContext(),
)
    topo_strat = supports_direct_strategy(topology) ? topology : resolve_topology(topology, ctx)
    route_alg  = _resolve_routing_any(routing, ctx)
    return topo_strat, route_alg
end

# 用户直接传 AbstractTopologyStrategy（高级用法）→ 原样返回
supports_direct_strategy(s::AbstractTopologyStrategy) = true
supports_direct_strategy(s) = false

# 路由：接受 AbstractRoutingAlgorithm 或 RoutingIntent
_resolve_routing_any(a::AbstractRoutingAlgorithm, ctx) = a
_resolve_routing_any(i::RoutingIntent, ctx) = resolve_routing(i, ctx)

# ════════════════════════════════════════════════════════════
# 星座意图翻译（三正交维度 → catalog 预设 or 自动构造）
# ════════════════════════════════════════════════════════════

"""
    resolve_constellation_intent(intent) -> WalkerConstellationConfig

把三维度星座意图翻译成 Walker 参数。先查预设表（已验证组合），
无预设则按维度参数自动构造合法 Walker 配置。
"""
function resolve_constellation_intent(intent::ConstellationIntent)
    # 1. 查预设表（已验证的优质组合 → catalog 符号）
    preset = lookup_constellation_preset(intent)
    preset !== nothing && return resolve_constellation(preset)

    # 2. 无预设：按维度参数自动构造
    inc = _inc_for(intent.coverage)
    alt = _alt_for(intent.latency)
    T, P = _tp_for(intent.scale)
    F = _phase_for(P)
    return WalkerConstellationConfig(T=T, P=P, F=F, alt_km=alt, inc_deg=inc)
end

# ── 预设表：已验证组合 → catalog 符号 ──
# 键 = (CoverageTarget 类型, LatencyTier 类型, Scale 类型)
# 只列已验证的优质组合；未列的走自动构造
const _CONSTELLATION_PRESETS = IdDict(
    (GlobalCoverage, LowLatencyConst,  MediumScale) => :walker72,
    (GlobalCoverage, LowLatencyConst,  LargeScale)  => :starlink_gen1,
    (PolarCoverage,  MidLatencyConst,  MediumScale) => :iridium,
    (PolarCoverage,  HighLatencyConst, MediumScale) => :telesat,
    (PolarCoverage,  HighLatencyConst, LargeScale)  => :oneweb,
    (GlobalCoverage, HighLatencyConst, LargeScale)  => :kuiper,
    (GlobalCoverage, LowLatencyConst,  SmallScale)  => :walker24,
)

"""
    lookup_constellation_preset(intent) -> Union{Symbol,Nothing}

查预设表，返回 catalog 符号或 nothing。
"""
function lookup_constellation_preset(intent::ConstellationIntent)
    key = (typeof(intent.coverage).name, typeof(intent.latency).name, typeof(intent.scale).name)
    # 注意：上面的 .name 在 IdDict 键里用的是类型本身，这里需要用 typeof 比较
    for (k, v) in _CONSTELLATION_PRESETS
        k[1] === typeof(intent.coverage) &&
        k[2] === typeof(intent.latency) &&
        k[3] === typeof(intent.scale) && return v
    end
    return nothing
end

# ── 维度参数表 ──
_inc_for(::GlobalCoverage) = 53.0    # 覆盖到中高纬
_inc_for(::PolarCoverage)  = 86.4    # 极轨
_inc_for(::MidLatCoverage) = 28.0    # 中低纬密集

_alt_for(::LowLatencyConst)  = 550.0   # Starlink 主壳
_alt_for(::MidLatencyConst)  = 780.0   # Iridium
_alt_for(::HighLatencyConst) = 1200.0  # OneWeb

_tp_for(::SmallScale)  = (48, 8)      # 实验用
_tp_for(::MediumScale) = (72, 8)      # 原型
_tp_for(::LargeScale)  = (1584, 72)   # 真实复现

_phase_for(P::Int) = P ÷ 4            # 默认相位参数

# ════════════════════════════════════════════════════════════
# 流量意图翻译（落到 Vector{TrafficDemand}，供执行链路真实消费）
# ════════════════════════════════════════════════════════════

"""
    TrafficResolutionContext

流量翻译专用上下文。依赖地面端点（数据）+ 已解析的时间窗。
"""
Base.@kwdef struct TrafficResolutionContext
    base::ResolutionContext = ResolutionContext()
    ground_ids::Vector{Int} = Int[]    # 地面端点 id 列表
    ground_pairs::Vector{Tuple{Int,Int}} = Tuple{Int,Int}[]  # 用户指定的 OD 对
    tspan::Vector{Float64} = [0.0]
end

"""
    resolve_traffic_intent(intent, tctx) -> Vector{TrafficDemand}

把流量意图翻译成具体 OD 需求列表。依赖地面端点 + 时间窗。
端点不足 2 个时返回空需求（不报错，降级）。
"""
function resolve_traffic_intent(intent::TrafficIntent, tctx::TrafficResolutionContext)
    gids = tctx.ground_ids
    pairs = tctx.ground_pairs
    length(gids) >= 2 || return TrafficDemand[]   # 端点不足，空需求
    isempty(pairs) && return TrafficDemand[]    # 未指定 OD 对，不生成流量
    t0 = Int(first(tctx.tspan))
    t1 = Int(last(tctx.tspan))
    duration = max(t1 - t0, 1)
    return _demands_for(intent, gids, pairs, t0, duration)
end

# 向后兼容：旧 Symbol（:uniform 等）→ 构造意图再翻译
resolve_traffic_intent(s::Symbol, tctx::TrafficResolutionContext) =
    resolve_traffic_intent(TRAFFIC_INTENTS[s](), tctx)

# 全对（不含自环）
_all_ground_pairs(gids) = [(a, b) for (i,a) in enumerate(gids) for b in gids[i+1:end]]

_demands_for(::UniformLoad, gids, pairs, t0, dur) =
    [TrafficDemand(id=k, source_ground_id=a, destination_ground_id=b,
                   start_elapsed_s=t0, end_elapsed_s=t0+dur, rate_mbps=50.0)
     for (k,(a,b)) in enumerate(pairs)]

function _demands_for(::HotspotLoad, gids, pairs, t0, dur)
    n = length(pairs)
    n_hot = max(1, round(Int, 0.2n))   # 20% 热点对
    [TrafficDemand(id=k, source_ground_id=a, destination_ground_id=b,
                   start_elapsed_s=t0, end_elapsed_s=t0+dur,
                   rate_mbps = k <= n_hot ? 200.0 : 10.0)
     for (k,(a,b)) in enumerate(pairs)]
end

_demands_for(::VideoLoad, gids, pairs, t0, dur) =
    [TrafficDemand(id=k, source_ground_id=a, destination_ground_id=b,
                   start_elapsed_s=t0, end_elapsed_s=t0+dur, rate_mbps=50.0)
     for (k,(a,b)) in enumerate(pairs)]

_demands_for(::IoTLoad, gids, pairs, t0, dur) =
    [TrafficDemand(id=k, source_ground_id=a, destination_ground_id=b,
                   start_elapsed_s=t0, end_elapsed_s=t0+dur, rate_mbps=1.0)
     for (k,(a,b)) in enumerate(pairs)]

# ════════════════════════════════════════════════════════════
# 传播器意图翻译（实现名词 TwoBody/J2/J4 关在此处）
# ════════════════════════════════════════════════════════════

"""
    resolve_propagator(intent, ctx)

把传播器意图翻译成具体传播器。实现名词被关在此处。

Keplerian 家族（SpeedFocus/BalancedProp/PrecisionFocus）返回
`AbstractKeplerianPropagator` 实例。TleBasedProp 返回符号 `:sgp4`——SGP4 需要
真实 TLE + 历元时间网格，与 Keplerian 路径输入完全不同，无法塞进同一个返回类型，
故用标记让实验路径（`_tool_run_simulation`）特判走独立 SGP4 分支。
"""
resolve_propagator(::SpeedFocus, ctx)     = TwoBodyPropagator()
resolve_propagator(::BalancedProp, ctx)   = J2Propagator()
resolve_propagator(::PrecisionFocus, ctx) = J4Propagator()
resolve_propagator(::TleBasedProp, ctx)   = :sgp4   # 标记：走 SGP4 独立路径

# 向后兼容：旧符号 :two_body/:j2/:j4/:tle_based
function resolve_propagator(s::Symbol, ctx)
    tbl = IdDict(:two_body => TwoBodyPropagator, :j2 => J2Propagator,
                 :j4 => J4Propagator, :tle_based => :sgp4)
    haskey(tbl, s) || error("未知传播器符号: $s（应传 PropagatorIntent 或 AbstractKeplerianPropagator）")
    return tbl[s] === :sgp4 ? :sgp4 : tbl[s]()
end
# 高级用户直传传播器
resolve_propagator(p::AbstractKeplerianPropagator, ctx) = p

# ════════════════════════════════════════════════════════════
# 物理约束意图翻译（实现名词 LEO_DEFAULTS 等关在此处）
# ════════════════════════════════════════════════════════════

"""
    resolve_constraint(intent, ctx) -> PhysicalConstraints

按轨道高度选基线预设，再按意图收紧/放松。实现名词被关在此处。
"""
function resolve_constraint(::BalancedLink, ctx)
    # 按高度自动选预设——用户不接触 LEO_DEFAULTS 这个名词
    ctx.alt_km < 2000 && return LEO_DEFAULTS
    # MEO/GEO 高度：从 LEO 派生（放宽 ISL 距离），不依赖未导出的 MEO/GEO 预设
    b = LEO_DEFAULTS
    scale = ctx.alt_km < 15000 ? 3.0 : 6.0   # MEO ×3, GEO ×6 距离
    return PhysicalConstraints(
        isl_max_range_km = b.isl_max_range_km * scale,
        isl_require_los = b.isl_require_los,
        isl_max_capacity_mbps = b.isl_max_capacity_mbps,
        gsl_min_elevation_deg = b.gsl_min_elevation_deg,
        gsl_max_range_km = b.gsl_max_range_km * scale,
        gsl_base_capacity_mbps = b.gsl_base_capacity_mbps,
        max_isl_per_satellite = b.max_isl_per_satellite,
        isl_max_cone_angle_deg = b.isl_max_cone_angle_deg,
        isl_min_azimuth_deg = b.isl_min_azimuth_deg,
        isl_min_duration_s = b.isl_min_duration_s,
        isl_setup_time_s = b.isl_setup_time_s,
    )
end

function resolve_constraint(::StrictLink, ctx)
    b = resolve_constraint(BalancedLink(), ctx)
    # 紧约束：短距离、高仰角、窄锥角（@kwdef 重新构造）
    return PhysicalConstraints(
        isl_max_range_km = b.isl_max_range_km * 0.7,
        isl_require_los = b.isl_require_los,
        isl_max_capacity_mbps = b.isl_max_capacity_mbps,
        gsl_min_elevation_deg = b.gsl_min_elevation_deg + 10.0,
        gsl_max_range_km = b.gsl_max_range_km,
        gsl_base_capacity_mbps = b.gsl_base_capacity_mbps,
        max_isl_per_satellite = b.max_isl_per_satellite,
        isl_max_cone_angle_deg = b.isl_max_cone_angle_deg - 15.0,
        isl_min_azimuth_deg = b.isl_min_azimuth_deg,
        isl_min_duration_s = b.isl_min_duration_s,
        isl_setup_time_s = b.isl_setup_time_s,
    )
end

function resolve_constraint(::RelaxedLink, ctx)
    b = resolve_constraint(BalancedLink(), ctx)
    # 松约束：长距离、低仰角、宽锥角
    return PhysicalConstraints(
        isl_max_range_km = b.isl_max_range_km * 1.4,
        isl_require_los = b.isl_require_los,
        isl_max_capacity_mbps = b.isl_max_capacity_mbps,
        gsl_min_elevation_deg = max(5.0, b.gsl_min_elevation_deg - 10.0),
        gsl_max_range_km = b.gsl_max_range_km,
        gsl_base_capacity_mbps = b.gsl_base_capacity_mbps,
        max_isl_per_satellite = b.max_isl_per_satellite,
        isl_max_cone_angle_deg = b.isl_max_cone_angle_deg + 15.0,
        isl_min_azimuth_deg = b.isl_min_azimuth_deg,
        isl_min_duration_s = b.isl_min_duration_s,
        isl_setup_time_s = b.isl_setup_time_s,
    )
end

# 向后兼容：直传 PhysicalConstraints 原样返回
resolve_constraint(c::PhysicalConstraints, ctx) = c

# ════════════════════════════════════════════════════════════
# 时间窗意图翻译（不暴露裸 tspan 向量构造）
# ════════════════════════════════════════════════════════════

# 开普勒第三定律算轨道周期（秒）
function _orbital_period_s(alt_km::Real)
    μ = 398600.4418  # km³/s²
    a_km = 6378.137 + alt_km
    return 2π * sqrt(a_km^3 / μ)
end

"""
    resolve_time_horizon(intent, ctx) -> Vector{Float64}

把时间窗意图翻译成 tspan 采样点向量。
"""
resolve_time_horizon(::SingleOrbit, ctx) = (T = _orbital_period_s(ctx.alt_km); collect(0.0:60.0:T))
resolve_time_horizon(::FullDay, ctx)     = collect(0.0:300.0:86400.0)
resolve_time_horizon(::Snapshot, ctx)    = [0.0]

# 向后兼容：直传 Vector 原样返回
resolve_time_horizon(v::AbstractVector{<:Real}, ctx) = Float64.(collect(v))

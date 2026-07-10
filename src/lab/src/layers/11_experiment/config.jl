# ===== Experiment configuration =====

export ExperimentConfig

struct ExperimentConfig
    name::String
    constellation::WalkerConstellationConfig
    propagator::AbstractKeplerianPropagator
    orbit_backend::Union{Nothing,OrbitBackendSpec}
    tspan::Vector{Float64}
    constraints::PhysicalConstraints
    topology_strategy::AbstractTopologyStrategy
    routing_algorithm::AbstractRoutingAlgorithm
    traffic_demands::Vector{TrafficDemand}    # 流量需求（由 TrafficIntent 翻译而来）
    ground_stations::Vector{GroundStation}
    users::Vector{GroundUser}
    random_seed::Int
    alpha::Float64
    ground_pairs::Vector{Tuple{Int,Int}}
end

# 把星座参数（意图/符号/直接配置）翻译成 WalkerConstellationConfig。
# 防泄漏：用户可传 ConstellationIntent（推荐）或 catalog 符号或直接 WalkerConstellationConfig。
_resolve_constellation_param(c::WalkerConstellationConfig) = c
# 向后兼容：接受 :walker48 等 catalog 符号（resolve_constellation 来自 SatelliteSimCore）
_resolve_constellation_param(s::Symbol) = SatelliteSimCore.resolve_constellation(s)
_resolve_constellation_param(intent::ConstellationIntent) = resolve_constellation_intent(intent)

# 后端选择只保存稳定规格，不把可选包的具体类型泄漏到实验配置。
_resolve_orbit_backend_param(::Nothing) = nothing
_resolve_orbit_backend_param(spec::OrbitBackendSpec) = spec
_resolve_orbit_backend_param(name::Union{Symbol,AbstractString}) = OrbitBackendSpec(name)
function _resolve_orbit_backend_param(value)
    throw(ArgumentError(
        "orbit_backend must be nothing, Symbol, String, or OrbitBackendSpec; got $(typeof(value))",
    ))
end

# 把拓扑参数（意图或策略）翻译成具体策略。
# 防泄漏关键：用户可传 TopologyIntent（推荐）或直接传策略（高级用法）。
_resolve_topo_param(x::AbstractTopologyStrategy, ctx) = x
_resolve_topo_param(s::Symbol, ctx) = resolve_topology(TOPLOGY_INTENTS[s](), ctx)
_resolve_topo_param(intent, ctx) = resolve_topology(intent, ctx)

# 路由参数同理
_resolve_routing_param(x::AbstractRoutingAlgorithm, ctx) = x
_resolve_routing_param(intent::RoutingIntent, ctx) = resolve_routing(intent, ctx)
function _resolve_routing_param(s::Symbol, ctx)
    # 优先查意图符号（:shortest_path/:load_balanced/:multipath）
    haskey(ROUTING_INTENTS, s) && return resolve_routing(ROUTING_INTENTS[s](), ctx)
    # 向后兼容：旧实现符号 :dijkstra/:ecmp/:min_load
    tbl = IdDict(:dijkstra => DijkstraRouting, :ecmp => ECMPRouting, :min_load => MinLoadRouting)
    haskey(tbl, s) || error("未知路由算法符号: $s（应传 RoutingIntent 或 AbstractRoutingAlgorithm）")
    return tbl[s]()
end

function ExperimentConfig(;
    name::AbstractString = "unnamed",
    # 接受 ConstellationIntent（推荐，防泄漏）或 catalog 符号（:walker48）或 WalkerConstellationConfig（高级）
    constellation = DefaultConstellation,
    constellation_params::Union{Nothing,Dict{Symbol,Float64}} = nothing,
    # 接受 PropagatorIntent（推荐）或 :two_body/:j2/:j4 符号或 AbstractKeplerianPropagator（高级）
    propagator = DefaultPropagator,
    # 可选后端只接受注册名或 OrbitBackendSpec；nothing 保持原生传播路径。
    orbit_backend = nothing,
    # 接受 TimeHorizonIntent（推荐）或裸 Vector{Float64}（高级）
    tspan = DefaultTimeHorizon,
    # 接受 ConstraintIntent（推荐）或 PhysicalConstraints（高级，如直传 LEO_DEFAULTS）
    constraints = DefaultConstraint,
    # 接受 TopologyIntent（推荐，防泄漏）或 AbstractTopologyStrategy（高级）
    topology_strategy = DefaultTopology,
    # 接受 RoutingIntent 或 AbstractRoutingAlgorithm 或 Symbol（向后兼容）
    routing_algorithm = DefaultRouting,
    # 接受 TrafficIntent（推荐）或 :uniform/:hotspot 等旧符号或 Vector{TrafficDemand}（高级）
    traffic = DefaultTraffic,
    ground_stations::Vector{GroundStation} = GroundStation[],
    users::Vector{GroundUser} = GroundUser[],
    random_seed::Integer = 42,
    alpha::Real = 0.5,
    ground_pairs::Vector{Tuple{Int,Int}} = Tuple{Int,Int}[],
)
    # 星座意图/符号/配置 → 统一为 WalkerConstellationConfig
    resolved_constellation = _resolve_constellation_param(constellation)
    # constellation_params（旧 API，Dict 形式）覆盖优先级最高
    if constellation_params !== nothing
        resolved_constellation = WalkerConstellationConfig(
            T=Int(constellation_params[:T]),
            P=Int(constellation_params[:P]),
            F=Int(constellation_params[:F]),
            alt_km=Float64(constellation_params[:alt_km]),
            inc_deg=Float64(constellation_params[:inc_deg]),
        )
    end
    # 构造翻译上下文（用星座规模决定 Mesh 等是否可行）
    ctx = ResolutionContext(T=resolved_constellation.T, P=resolved_constellation.P,
                            alt_km=resolved_constellation.alt_km,
                            inc_deg=resolved_constellation.inc_deg)
    # 先解析 tspan（流量翻译依赖它）
    resolved_tspan = resolve_time_horizon(tspan, ctx)
    # 流量翻译：依赖 ground 数据 + tspan（端点不足时降级为空需求）
    ground_ids = isempty(ground_pairs) ? Int[] : unique!(sort(vcat(first.(ground_pairs), last.(ground_pairs))))
    tctx = TrafficResolutionContext(base=ctx, ground_ids=ground_ids, tspan=resolved_tspan)
    resolved_traffic = traffic isa Vector{TrafficDemand} ? traffic :
                       traffic isa TrafficIntent ? resolve_traffic_intent(traffic, tctx) :
                       traffic isa Symbol ? resolve_traffic_intent(traffic, tctx) :
                       TrafficDemand[]
    return ExperimentConfig(
        String(name),
        resolved_constellation,
        resolve_propagator(propagator, ctx),
        _resolve_orbit_backend_param(orbit_backend),
        resolved_tspan,
        resolve_constraint(constraints, ctx),
        _resolve_topo_param(topology_strategy, ctx),
        _resolve_routing_param(routing_algorithm, ctx),
        resolved_traffic,
        ground_stations,
        users,
        Int(random_seed),
        Float64(alpha),
        ground_pairs,
    )
end

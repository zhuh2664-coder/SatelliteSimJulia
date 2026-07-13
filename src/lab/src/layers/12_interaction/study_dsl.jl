# ===== Study DSL — 声明式实验配置 =====
# 轻量层，将 ~80 行参数组装压缩为 ~15 行声明。
#
# 用法（推荐：传意图，不碰实现名词）:
#   @study "coverage_china" begin
#       constellation = ConstellationIntent(coverage=GlobalCoverage(), scale=MediumScale())
#       propagator = BalancedProp()       # 不暴露 :two_body/:j2/:j4
#       topology = BalancedTopo()         # 不暴露 GridPlus/Honeycomb
#       routing = ShortestPath()          # 不暴露 Dijkstra/ECMP
#   end
#
# 等价于:
#   study("coverage_china";
#       constellation = ConstellationIntent(coverage=GlobalCoverage(), scale=MediumScale()),
#       propagator = BalancedProp(),
#       topology = BalancedTopo(),
#       routing = ShortestPath())

export study, walker

using SatelliteSimCore: WalkerConstellationConfig

"""Walker 星座配置快捷构造"""
function walker(T::Int, P::Int; F::Int=1, alt_km::Real=550.0, inc_deg::Real=53.0)
    return WalkerConstellationConfig(T=T, P=P, F=F, alt_km=Float64(alt_km), inc_deg=Float64(inc_deg))
end

"""声明式实验配置（函数版）"""
function study(name::String;
    constellation = DefaultConstellation,  # 默认走意图翻译；可传意图/符号/WalkerConfig
    propagator = DefaultPropagator,        # 默认走意图翻译（BalancedProp→J2）
    tspan = DefaultTimeHorizon,            # 默认走意图翻译（SingleOrbit）
    topology = nothing,   # 接受 TopologyIntent（推荐）或具体策略
    routing = nothing,    # 接受 RoutingIntent 或具体算法
    constraints = nothing, # 接受 ConstraintIntent 或 PhysicalConstraints
    ground_endpoints = nothing,
    ground_stations = nothing,
    users = nothing,
    random_seed::Int = 42,
    kwargs...)
    return ExperimentConfig(;
        name = name,
        constellation = constellation,
        propagator = propagator,
        tspan = tspan,
        # 默认走意图翻译（DefaultTopology），用户可传意图或策略覆盖
        topology_strategy = something(topology, DefaultTopology),
        routing_algorithm = something(routing, DefaultRouting),
        constraints = something(constraints, LEO_DEFAULTS),
        ground_endpoints = something(ground_endpoints, GroundEndpoint[]),
        ground_stations = something(ground_stations, GroundStation[]),
        users = something(users, GroundUser[]),
        random_seed = random_seed,
        kwargs...,
    )
end

"""声明式实验配置（块宏版，语法糖）"""
macro study(name_expr, block)
    kw_exprs = Expr[]
    for stmt in block.args
        # Skip LineNumberNode and other non-assignment nodes
        stmt isa Expr && stmt.head == :(=) || continue
        k, v = stmt.args[1], stmt.args[2]
        push!(kw_exprs, :($(esc(k)) = $(esc(v))))
    end
    return :(study($(esc(name_expr)); $(kw_exprs...)))
end

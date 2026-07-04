# ===== Experiment planner =====

export StudyPlan, create_plan, build_study,
       GOAL_PARAM_BUILDERS, register_goal_param_builder!

struct StudyPlan
    goal::Symbol
    study_type::DataType
    parameters::Dict{Symbol,Any}
end

const GOAL_PARAM_BUILDERS = Dict{Symbol,Function}()

function register_goal_param_builder!(goal::Symbol, builder_fn::Function)
    GOAL_PARAM_BUILDERS[goal] = builder_fn
    return goal
end

build_study(::Type{RoutingStudy}, p) = RoutingStudy(
    algorithms=get(p, :algorithms, [:shortest_path]),
    constellation=get(p, :constellation, :walker48),
    traffic=get(p, :traffic, :uniform),
    metrics=get(p, :metrics, [:latency, :coverage]),
)

build_study(::Type{ConstellationStudy}, p) = ConstellationStudy(
    constellations=get(p, :constellations, [:walker24, :walker48]),
    routing=get(p, :routing, :shortest_path),
    traffic=get(p, :traffic, :uniform),
    metrics=get(p, :metrics, [:latency, :coverage]),
)

build_study(::Type{CapacityStudy}, p) = CapacityStudy(
    user_counts=get(p, :user_counts, [100, 500, 1000]),
    constellation=get(p, :constellation, :walker48),
    routing=get(p, :routing, :shortest_path),
)

build_study(::Type{VulnerabilityStudy}, p) = VulnerabilityStudy(
    constellation=get(p, :constellation, :walker48),
    metrics=get(p, :metrics, [:connectivity, :diameter]),
)

build_study(::Type{CacheStudy}, p) = CacheStudy(
    constellation=get(p, :constellation, :walker48),
    storage_range=get(p, :storage_range, [100.0, 500.0, 1000.0]),
)

build_study(::Type{CoverageStudy}, p) = CoverageStudy(
    constellation=get(p, :constellation, :walker48),
    lat_bounds=get(p, :lat_bounds, (-70.0, 70.0)),
)

function _default_goal_builder(goal::Symbol, answers::Dict)
    g = goal_info(goal)
    # 星座意图：从三维度答案组装
    rec = first(g.recommended_constellation)
    cov = get(answers, :constellation_coverage, rec[1])
    lat = get(answers, :constellation_latency, rec[2])
    scl = get(answers, :constellation_scale, rec[3])
    intent = ConstellationIntent(;
        coverage = COVERAGE_TARGETS[cov](),
        latency  = LATENCY_TIERS[lat](),
        scale    = CONSTELLATION_SCALES[scl](),
    )
    params = Dict{Symbol,Any}(
        :constellation => intent,
        :topology_intent => get(answers, :topology_intent, first(g.recommended_topology)),
        :traffic_intent => get(answers, :traffic_intent, :uniform),
        :metrics => get(answers, :metrics, g.recommended_metrics),
    )

    if goal == :routing_comparison
        params[:algorithms] = get(answers, :algorithms, g.recommended_routing)
    elseif goal == :constellation_comparison
        params[:constellations] = get(answers, :constellations, [:walker24, :walker48])
        params[:routing] = get(answers, :routing, first(g.recommended_routing))
    elseif goal == :capacity_analysis
        params[:user_counts] = get(answers, :user_counts, [100, 500, 1000])
        params[:routing] = get(answers, :routing, first(g.recommended_routing))
    elseif goal == :coverage_analysis
        params[:lat_bounds] = get(answers, :lat_bounds, (-70.0, 70.0))
    elseif goal == :cache_analysis
        params[:storage_range] = get(answers, :storage_range, [100.0, 500.0, 1000.0])
    end

    return params
end

function create_plan(answers::Dict)
    goal = answers[:goal]
    g = goal_info(goal)
    builder = get(GOAL_PARAM_BUILDERS, goal, _default_goal_builder)
    return StudyPlan(goal, g.recommended_study, builder(goal, answers))
end

function build_study(plan::StudyPlan)
    return build_study(plan.study_type, plan.parameters)
end

function create_study(goal::Symbol; kwargs...)
    g = goal_info(goal)
    params = Dict{Symbol,Any}(kwargs)
    if !haskey(params, :traffic)
        params[:traffic] = first(g.recommended_traffic)
    end
    if !haskey(params, :metrics)
        params[:metrics] = g.recommended_metrics
    end
    return build_study(StudyPlan(goal, g.recommended_study, params))
end

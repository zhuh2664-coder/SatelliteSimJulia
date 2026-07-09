# ===== Lightweight Study definitions =====

export Study, StudyGoal, CoverageGoal, LatencyGoal, CostGoal,
       RoutingStudy, ConstellationStudy, CapacityStudy,
       VulnerabilityStudy, CacheStudy, CoverageStudy,
       study_name, STUDY_REGISTRY, list_studies, describe_study,
       create_study

abstract type StudyGoal end
struct CoverageGoal <: StudyGoal end
struct LatencyGoal <: StudyGoal end
struct CostGoal <: StudyGoal end

abstract type Study end

struct RoutingStudy <: Study
    algorithms::Vector{Symbol}
    constellation::Symbol
    traffic::Symbol
    metrics::Vector{Symbol}
    goal::StudyGoal
end

RoutingStudy(;
    algorithms=[:shortest_path],
    constellation=:walker48,
    traffic=:uniform,
    metrics=[:latency, :coverage],
    goal=LatencyGoal(),
) = RoutingStudy(Symbol.(algorithms), Symbol(constellation), Symbol(traffic), Symbol.(metrics), goal)

struct ConstellationStudy <: Study
    constellations::Vector{Symbol}
    routing::Symbol
    traffic::Symbol
    metrics::Vector{Symbol}
    goal::StudyGoal
end

ConstellationStudy(;
    constellations=[:walker24, :walker48],
    routing=:shortest_path,
    traffic=:uniform,
    metrics=[:latency, :coverage],
    goal=CoverageGoal(),
) = ConstellationStudy(Symbol.(constellations), Symbol(routing), Symbol(traffic), Symbol.(metrics), goal)

struct CapacityStudy <: Study
    user_counts::Vector{Int}
    constellation::Symbol
    routing::Symbol
    goal::StudyGoal
end

CapacityStudy(;
    user_counts=[100, 500, 1000],
    constellation=:walker48,
    routing=:shortest_path,
    goal=CostGoal(),
) = CapacityStudy(Int.(user_counts), Symbol(constellation), Symbol(routing), goal)

struct VulnerabilityStudy <: Study
    constellation::Symbol
    metrics::Vector{Symbol}
    goal::StudyGoal
end

VulnerabilityStudy(;
    constellation=:walker48,
    metrics=[:connectivity, :diameter],
    goal=CostGoal(),
) = VulnerabilityStudy(Symbol(constellation), Symbol.(metrics), goal)

struct CacheStudy <: Study
    constellation::Symbol
    storage_range::Vector{Float64}
    goal::StudyGoal
end

CacheStudy(;
    constellation=:walker48,
    storage_range=[100.0, 500.0, 1000.0],
    goal=LatencyGoal(),
) = CacheStudy(Symbol(constellation), Float64.(storage_range), goal)

struct CoverageStudy <: Study
    constellation::Symbol
    lat_bounds::Tuple{Float64,Float64}
    goal::StudyGoal
end

CoverageStudy(;
    constellation=:walker48,
    lat_bounds=(-70.0, 70.0),
    goal=CoverageGoal(),
) = CoverageStudy(Symbol(constellation), (Float64(lat_bounds[1]), Float64(lat_bounds[2])), goal)

study_name(::RoutingStudy) = "routing"
study_name(::ConstellationStudy) = "constellation"
study_name(::CapacityStudy) = "capacity"
study_name(::VulnerabilityStudy) = "vulnerability"
study_name(::CacheStudy) = "cache"
study_name(::CoverageStudy) = "coverage"

const STUDY_REGISTRY = Dict{String,DataType}(
    "routing" => RoutingStudy,
    "constellation" => ConstellationStudy,
    "capacity" => CapacityStudy,
    "vulnerability" => VulnerabilityStudy,
    "cache" => CacheStudy,
    "coverage" => CoverageStudy,
)

list_studies() = sort(collect(keys(STUDY_REGISTRY)))

function describe_study(name::String)
    haskey(STUDY_REGISTRY, name) || return "unknown study: $name"
    return "Study: $name\nType:  $(STUDY_REGISTRY[name])"
end

# ============================================================
# Study → ExperimentConfig → 执行（闭环：Study 不再是死对象）
# ============================================================
#
# run(::Study) 把 Study 的 Symbol 字段翻译成意图，构造 ExperimentConfig，
# 调 run_experiment。这激活了 create_plan → build_study → run 的完整链。
#
# Symbol 翻译：Study 用 catalog 符号（如 :shortest_path/:uniform），
# 直接传给 ExperimentConfig（它接受 Symbol 并内部 resolve）。

export run_study

"""
    run_study(study::Study) -> ExperimentResult

把 Study 翻译成 ExperimentConfig 并执行。激活 Study→执行链。
"""
function run_study(
    study::Study;
    ground_stations::Vector{GroundStation} = GroundStation[],
    ground_pairs::Vector{Tuple{Int,Int}} = Tuple{Int,Int}[],
)
    config = _study_to_config(study)
    config = _with_study_runtime_context(
        config;
        traffic = _study_traffic(study),
        ground_stations = ground_stations,
        ground_pairs = ground_pairs,
    )
    return run_experiment(config)
end

_study_traffic(s::RoutingStudy) = s.traffic
_study_traffic(s::ConstellationStudy) = s.traffic
_study_traffic(::CapacityStudy) = :hotspot
_study_traffic(::CacheStudy) = :video
_study_traffic(::CoverageStudy) = :uniform
_study_traffic(::VulnerabilityStudy) = TrafficDemand[]

function _with_study_runtime_context(
    config;
    traffic = config.traffic_demands,
    ground_stations::Vector{GroundStation} = GroundStation[],
    ground_pairs::Vector{Tuple{Int,Int}} = Tuple{Int,Int}[],
)
    isempty(ground_stations) && isempty(ground_pairs) && return config
    return ExperimentConfig(;
        name = config.name,
        constellation = config.constellation,
        propagator = config.propagator,
        tspan = config.tspan,
        constraints = config.constraints,
        topology_strategy = config.topology_strategy,
        routing_algorithm = config.routing_algorithm,
        traffic = traffic,
        ground_stations = isempty(ground_stations) ? config.ground_stations : ground_stations,
        users = config.users,
        random_seed = config.random_seed,
        alpha = config.alpha,
        ground_pairs = isempty(ground_pairs) ? config.ground_pairs : ground_pairs,
    )
end

# RoutingStudy → Config（路由对比：固定星座，比路由算法）
function _study_to_config(s::RoutingStudy)
    ExperimentConfig(;
        name = "routing_study",
        routing_algorithm = first(s.algorithms),  # 用第一个算法（对比需循环调多次）
        traffic = s.traffic,
        topology_strategy = BalancedTopo(),
    )
end

# ConstellationStudy → Config（星座对比：固定路由，比星座）
function _study_to_config(s::ConstellationStudy)
    ExperimentConfig(;
        name = "constellation_study",
        routing_algorithm = s.routing,
        traffic = s.traffic,
    )
end

# CapacityStudy → Config（容量分析）
function _study_to_config(s::CapacityStudy)
    ExperimentConfig(;
        name = "capacity_study",
        routing_algorithm = s.routing,
        traffic = :hotspot,  # 容量场景用热点流量
    )
end

# VulnerabilityStudy → Config（脆弱性分析）
_study_to_config(s::VulnerabilityStudy) = ExperimentConfig(; name = "vulnerability_study")

# CacheStudy → Config（缓存分析）
_study_to_config(s::CacheStudy) = ExperimentConfig(; name = "cache_study", traffic = :video)

# CoverageStudy → Config（覆盖分析）
_study_to_config(s::CoverageStudy) = ExperimentConfig(; name = "coverage_study", traffic = :uniform)

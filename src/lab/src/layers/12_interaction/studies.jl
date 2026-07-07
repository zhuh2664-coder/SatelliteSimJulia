# ===== Lightweight Study definitions =====

using Dates

export Study, StudyGoal, CoverageGoal, LatencyGoal, CostGoal,
       RoutingStudy, ConstellationStudy, CapacityStudy,
       VulnerabilityStudy, CacheStudy, CoverageStudy,
       StudyRunCase, StudyRunCaseResult, StudyRunResult,
       study_name, STUDY_REGISTRY, list_studies, describe_study,
       create_study, run_study, expand_study, run_study_plan, study_run_manifest

abstract type StudyGoal end
struct CoverageGoal <: StudyGoal end
struct LatencyGoal <: StudyGoal end
struct CostGoal <: StudyGoal end

abstract type Study end

_normalize_study_spec(x) = x isa AbstractString ? Symbol(x) : x
_normalize_study_specs(xs) = Any[_normalize_study_spec(x) for x in xs]
_normalize_metric_specs(xs) = Symbol.([_normalize_study_spec(x) for x in xs])

struct RoutingStudy <: Study
    algorithms::Vector{Any}
    constellation::Any
    traffic::Any
    metrics::Vector{Symbol}
    goal::StudyGoal
end

RoutingStudy(;
    algorithms=[:shortest_path],
    constellation=:walker48,
    traffic=:uniform,
    metrics=[:latency, :coverage],
    goal=LatencyGoal(),
) = RoutingStudy(
    _normalize_study_specs(algorithms),
    _normalize_study_spec(constellation),
    _normalize_study_spec(traffic),
    _normalize_metric_specs(metrics),
    goal,
)

struct ConstellationStudy <: Study
    constellations::Vector{Any}
    routing::Any
    traffic::Any
    metrics::Vector{Symbol}
    goal::StudyGoal
end

ConstellationStudy(;
    constellations=[:walker24, :walker48],
    routing=:shortest_path,
    traffic=:uniform,
    metrics=[:latency, :coverage],
    goal=CoverageGoal(),
) = ConstellationStudy(
    _normalize_study_specs(constellations),
    _normalize_study_spec(routing),
    _normalize_study_spec(traffic),
    _normalize_metric_specs(metrics),
    goal,
)

struct CapacityStudy <: Study
    user_counts::Vector{Int}
    constellation::Any
    routing::Any
    goal::StudyGoal
end

CapacityStudy(;
    user_counts=[100, 500, 1000],
    constellation=:walker48,
    routing=:shortest_path,
    goal=CostGoal(),
) = CapacityStudy(Int.(user_counts), _normalize_study_spec(constellation), _normalize_study_spec(routing), goal)

struct VulnerabilityStudy <: Study
    constellation::Any
    metrics::Vector{Symbol}
    goal::StudyGoal
end

VulnerabilityStudy(;
    constellation=:walker48,
    metrics=[:connectivity, :diameter],
    goal=CostGoal(),
) = VulnerabilityStudy(_normalize_study_spec(constellation), _normalize_metric_specs(metrics), goal)

struct CacheStudy <: Study
    constellation::Any
    storage_range::Vector{Float64}
    goal::StudyGoal
end

CacheStudy(;
    constellation=:walker48,
    storage_range=[100.0, 500.0, 1000.0],
    goal=LatencyGoal(),
) = CacheStudy(_normalize_study_spec(constellation), Float64.(storage_range), goal)

struct CoverageStudy <: Study
    constellation::Any
    lat_bounds::Tuple{Float64,Float64}
    goal::StudyGoal
end

CoverageStudy(;
    constellation=:walker48,
    lat_bounds=(-70.0, 70.0),
    goal=CoverageGoal(),
) = CoverageStudy(_normalize_study_spec(constellation), (Float64(lat_bounds[1]), Float64(lat_bounds[2])), goal)

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
# run_study 保持旧语义：返回一个代表性 ExperimentResult。
# run_study_plan 是新的编排入口：展开少量 case，返回 StudyRunResult/manifest。

Base.@kwdef struct StudyRunCase
    id::String
    label::String
    axis::Symbol
    value::Any
    config::ExperimentConfig
    warnings::Vector{String} = String[]
end

Base.@kwdef struct StudyRunCaseResult
    case::StudyRunCase
    status::Symbol
    result::Union{ExperimentResult,Nothing} = nothing
    error::Union{String,Nothing} = nothing
end

Base.@kwdef struct StudyRunResult
    id::String
    plan::Any = nothing
    study::Study
    cases::Vector{StudyRunCaseResult}
    status::Symbol
    started_at::DateTime
    completed_at::DateTime
    warnings::Vector{String} = String[]
end

_run_id(prefix::AbstractString="study_run") = prefix * "_" * Dates.format(now(), "yyyymmdd_HHMMSS")
_slug(x) = replace(lowercase(string(x)), r"[^a-z0-9]+" => "_")

function _limited_axis(values::AbstractVector, max_cases::Int, warnings::Vector{String}, axis::Symbol)
    max_cases > 0 || error("max_cases must be positive")
    if length(values) > max_cases
        push!(warnings, "$(axis) case count $(length(values)) truncated to max_cases=$max_cases")
        return values[1:max_cases]
    end
    return values
end

function _maybe_tspan(tspan)
    tspan === nothing && return nothing
    return Float64.(collect(tspan))
end

function _config_with_optional_tspan(; tspan=nothing, kwargs...)
    ts = _maybe_tspan(tspan)
    if ts === nothing
        return ExperimentConfig(; kwargs...)
    end
    return ExperimentConfig(; kwargs..., tspan = ts)
end

function _study_to_config(s::RoutingStudy;
    name::AbstractString = "routing_study",
    routing_algorithm = first(s.algorithms),
    ground_stations::Vector{GroundStation} = GroundStation[],
    ground_pairs::Vector{Tuple{Int,Int}} = Tuple{Int,Int}[],
    users::Vector{GroundUser} = GroundUser[],
    tspan = nothing,
    random_seed::Integer = 42,
)
    return _config_with_optional_tspan(;
        name = name,
        constellation = s.constellation,
        routing_algorithm = routing_algorithm,
        traffic = s.traffic,
        topology_strategy = BalancedTopo(),
        ground_stations = ground_stations,
        ground_pairs = ground_pairs,
        users = users,
        random_seed = random_seed,
        tspan = tspan,
    )
end

function _study_to_config(s::ConstellationStudy;
    name::AbstractString = "constellation_study",
    constellation = first(s.constellations),
    ground_stations::Vector{GroundStation} = GroundStation[],
    ground_pairs::Vector{Tuple{Int,Int}} = Tuple{Int,Int}[],
    users::Vector{GroundUser} = GroundUser[],
    tspan = nothing,
    random_seed::Integer = 42,
)
    return _config_with_optional_tspan(;
        name = name,
        constellation = constellation,
        routing_algorithm = s.routing,
        traffic = s.traffic,
        ground_stations = ground_stations,
        ground_pairs = ground_pairs,
        users = users,
        random_seed = random_seed,
        tspan = tspan,
    )
end

function _capacity_users(count::Integer)
    n = max(0, Int(count))
    return GroundUser[
        GroundUser("user_$i", -45.0 + mod(i - 1, 10) * 10.0, -120.0 + fld(i - 1, 10) * 12.0, 1.0, 5.0, "capacity")
        for i in 1:n
    ]
end

function _study_to_config(s::CapacityStudy;
    name::AbstractString = "capacity_study",
    user_count::Integer = isempty(s.user_counts) ? 0 : first(s.user_counts),
    ground_stations::Vector{GroundStation} = GroundStation[],
    ground_pairs::Vector{Tuple{Int,Int}} = Tuple{Int,Int}[],
    users::Vector{GroundUser} = _capacity_users(user_count),
    tspan = nothing,
    random_seed::Integer = 42,
)
    return _config_with_optional_tspan(;
        name = name,
        constellation = s.constellation,
        routing_algorithm = s.routing,
        traffic = :hotspot,
        ground_stations = ground_stations,
        ground_pairs = ground_pairs,
        users = users,
        random_seed = random_seed,
        tspan = tspan,
    )
end

function _study_to_config(s::VulnerabilityStudy;
    name::AbstractString = "vulnerability_study",
    ground_stations::Vector{GroundStation} = GroundStation[],
    ground_pairs::Vector{Tuple{Int,Int}} = Tuple{Int,Int}[],
    users::Vector{GroundUser} = GroundUser[],
    tspan = nothing,
    random_seed::Integer = 42,
)
    return _config_with_optional_tspan(;
        name = name,
        constellation = s.constellation,
        ground_stations = ground_stations,
        ground_pairs = ground_pairs,
        users = users,
        random_seed = random_seed,
        tspan = tspan,
    )
end

function _study_to_config(s::CacheStudy;
    name::AbstractString = "cache_study",
    ground_stations::Vector{GroundStation} = GroundStation[],
    ground_pairs::Vector{Tuple{Int,Int}} = Tuple{Int,Int}[],
    users::Vector{GroundUser} = GroundUser[],
    tspan = nothing,
    random_seed::Integer = 42,
)
    return _config_with_optional_tspan(;
        name = name,
        constellation = s.constellation,
        traffic = :video,
        ground_stations = ground_stations,
        ground_pairs = ground_pairs,
        users = users,
        random_seed = random_seed,
        tspan = tspan,
    )
end

function _coverage_users(bounds::Tuple{Float64,Float64})
    lo, hi = bounds
    mid = (lo + hi) / 2
    return GroundUser[
        GroundUser("coverage_low", lo, 0.0, 0.0, 1.0, "coverage"),
        GroundUser("coverage_mid", mid, 45.0, 0.0, 1.0, "coverage"),
        GroundUser("coverage_high", hi, -45.0, 0.0, 1.0, "coverage"),
    ]
end

function _study_to_config(s::CoverageStudy;
    name::AbstractString = "coverage_study",
    ground_stations::Vector{GroundStation} = GroundStation[],
    ground_pairs::Vector{Tuple{Int,Int}} = Tuple{Int,Int}[],
    users::Vector{GroundUser} = _coverage_users(s.lat_bounds),
    tspan = nothing,
    random_seed::Integer = 42,
)
    return _config_with_optional_tspan(;
        name = name,
        constellation = s.constellation,
        traffic = :uniform,
        ground_stations = ground_stations,
        ground_pairs = ground_pairs,
        users = users,
        random_seed = random_seed,
        tspan = tspan,
    )
end

function run_study(study::Study; kwargs...)
    config = _study_to_config(study; kwargs...)
    return run_experiment(config)
end

function _case(id, label, axis, value, config; warnings=String[])
    return StudyRunCase(
        id = String(id),
        label = String(label),
        axis = axis,
        value = value,
        config = config,
        warnings = copy(warnings),
    )
end

function expand_study(s::RoutingStudy; max_cases::Int = 8, kwargs...)
    warnings = String[]
    algorithms = _limited_axis(s.algorithms, max_cases, warnings, :routing)
    return [
        _case(
            "routing_" * _slug(algorithm),
            "routing=$(algorithm)",
            :routing,
            algorithm,
            _study_to_config(s; name = "routing_$(algorithm)", routing_algorithm = algorithm, kwargs...);
            warnings = warnings,
        ) for algorithm in algorithms
    ]
end

function expand_study(s::ConstellationStudy; max_cases::Int = 8, kwargs...)
    warnings = String[]
    constellations = _limited_axis(s.constellations, max_cases, warnings, :constellation)
    return [
        _case(
            "constellation_" * _slug(constellation),
            "constellation=$(constellation)",
            :constellation,
            constellation,
            _study_to_config(s; name = "constellation_$(constellation)", constellation = constellation, kwargs...);
            warnings = warnings,
        ) for constellation in constellations
    ]
end

function expand_study(s::CapacityStudy; max_cases::Int = 8, kwargs...)
    warnings = String[]
    counts = _limited_axis(s.user_counts, max_cases, warnings, :user_count)
    return [
        _case(
            "capacity_users_$(count)",
            "user_count=$(count)",
            :user_count,
            count,
            _study_to_config(s; name = "capacity_users_$(count)", user_count = count, kwargs...);
            warnings = warnings,
        ) for count in counts
    ]
end

function expand_study(s::CoverageStudy; max_cases::Int = 8, kwargs...)
    return [_case("coverage_representative", "coverage representative", :representative, s.lat_bounds, _study_to_config(s; kwargs...))]
end

function expand_study(s::VulnerabilityStudy; max_cases::Int = 8, kwargs...)
    warnings = ["vulnerability failure model is not wired into StudyRun yet; running representative baseline"]
    return [_case("vulnerability_representative", "vulnerability representative", :representative, :baseline, _study_to_config(s; kwargs...); warnings = warnings)]
end

function expand_study(s::CacheStudy; max_cases::Int = 8, kwargs...)
    warnings = ["cache storage_range is not wired into StudyRun yet; running representative baseline"]
    return [_case("cache_representative", "cache representative", :representative, first(s.storage_range), _study_to_config(s; kwargs...); warnings = warnings)]
end

function _study_run_status(case_results::Vector{StudyRunCaseResult})
    isempty(case_results) && return :failed
    all(cr -> cr.status === :succeeded, case_results) && return :succeeded
    any(cr -> cr.status === :succeeded, case_results) && return :partial
    return :failed
end

function _run_study_cases(study::Study; plan=nothing, max_cases::Int = 8, continue_on_error::Bool = false, run_id::String = _run_id(), kwargs...)
    started = now()
    cases = expand_study(study; max_cases = max_cases, kwargs...)
    results = StudyRunCaseResult[]
    run_warnings = String[]
    for case in cases
        append!(run_warnings, case.warnings)
        try
            push!(results, StudyRunCaseResult(case = case, status = :succeeded, result = run_experiment(case.config)))
        catch e
            push!(results, StudyRunCaseResult(case = case, status = :failed, error = sprint(showerror, e)))
            continue_on_error || break
        end
    end
    completed = now()
    return StudyRunResult(
        id = run_id,
        plan = plan,
        study = study,
        cases = results,
        status = _study_run_status(results),
        started_at = started,
        completed_at = completed,
        warnings = unique(run_warnings),
    )
end

run_study_plan(study::Study; kwargs...) = _run_study_cases(study; kwargs...)

function run_study_plan(plan; kwargs...)
    study = build_study(plan)
    return _run_study_cases(study; plan = plan, kwargs...)
end

function _study_config_summary(config::ExperimentConfig)
    c = config.constellation
    tspan = config.tspan
    return Dict{String,Any}(
        "name" => config.name,
        "T" => c.T,
        "P" => c.P,
        "F" => c.F,
        "alt_km" => c.alt_km,
        "inc_deg" => c.inc_deg,
        "tspan_count" => length(tspan),
        "tspan_start_s" => isempty(tspan) ? nothing : first(tspan),
        "tspan_end_s" => isempty(tspan) ? nothing : last(tspan),
        "propagator" => string(typeof(config.propagator)),
        "topology" => string(typeof(config.topology_strategy)),
        "routing" => string(typeof(config.routing_algorithm)),
        "traffic_demands" => length(config.traffic_demands),
        "ground_stations" => length(config.ground_stations),
        "ground_pairs" => length(config.ground_pairs),
        "users" => length(config.users),
        "random_seed" => config.random_seed,
    )
end

function _study_traffic_totals(traffic_evaluation)
    traffic_evaluation === nothing && return (offered_mbps = 0.0, carried_mbps = 0.0, dropped_mbps = 0.0)
    offered = 0.0
    carried = 0.0
    dropped = 0.0
    for assignments in traffic_evaluation.assignments_by_time
        for assignment in assignments
            offered += assignment.offered_mbps
            carried += assignment.carried_mbps
            dropped += assignment.dropped_mbps
        end
    end
    return (offered_mbps = offered, carried_mbps = carried, dropped_mbps = dropped)
end

function _study_result_summary(result::ExperimentResult)
    base = Dict{String,Any}(string(k) => v for (k, v) in to_dict(result))
    traffic_evaluation = result.traffic_evaluation
    totals = _study_traffic_totals(traffic_evaluation)
    base["traffic_evaluation_ran"] = traffic_evaluation !== nothing
    base["traffic_fallback"] = !isempty(result.config.traffic_demands) && traffic_evaluation === nothing
    base["traffic_time_steps"] = traffic_evaluation === nothing ? 0 : length(traffic_evaluation.assignments_by_time)
    base["traffic_assignments"] = traffic_evaluation === nothing ? 0 : sum(length, traffic_evaluation.assignments_by_time)
    base["offered_mbps"] = round(totals.offered_mbps, digits = 3)
    base["carried_mbps"] = round(totals.carried_mbps, digits = 3)
    base["dropped_mbps"] = round(totals.dropped_mbps, digits = 3)
    return base
end

function _study_result_pairs(run::StudyRunResult)
    pairs = Pair{String,ExperimentResult}[]
    for cr in run.cases
        if cr.status === :succeeded && cr.result !== nothing
            push!(pairs, cr.case.label => cr.result)
        end
    end
    return pairs
end

function _study_run_artifacts(run::StudyRunResult)
    pairs = _study_result_pairs(run)
    return Dict{String,Any}(
        "summary_csv" => isempty(pairs) ? "" : to_csv(pairs),
        "summary_markdown" => isempty(pairs) ? "" : to_markdown(pairs),
    )
end

function study_run_manifest(run::StudyRunResult)
    return Dict{String,Any}(
        "schema_version" => "study_run/v1",
        "run_id" => run.id,
        "status" => string(run.status),
        "study" => study_name(run.study),
        "goal" => run.plan === nothing ? nothing : string(getproperty(run.plan, :goal)),
        "case_count" => length(run.cases),
        "started_at" => string(run.started_at),
        "completed_at" => string(run.completed_at),
        "warnings" => run.warnings,
        "cases" => [
            Dict{String,Any}(
                "case_id" => cr.case.id,
                "label" => cr.case.label,
                "axis" => string(cr.case.axis),
                "value" => string(cr.case.value),
                "status" => string(cr.status),
                "config" => _study_config_summary(cr.case.config),
                "metrics" => cr.result === nothing ? nothing : _study_result_summary(cr.result),
                "warnings" => cr.case.warnings,
                "error" => cr.error,
            ) for cr in run.cases
        ],
        "artifacts" => _study_run_artifacts(run),
    )
end

# ===== Goal / planner AI tools =====
#
# 把 GOAL_CATALOG / create_plan / build_study 接入 LLM 工具层。

export register_planner_ai_tools!

function _tool_list_goals(args::AbstractDict)
    return Dict("goals" => [
        Dict(
            "id" => string(id),
            "name" => GOAL_CATALOG[id].name,
            "description" => GOAL_CATALOG[id].description,
        ) for id in list_goals()
    ])
end

function _tool_describe_goal(args::AbstractDict)
    goal = Symbol(String(get(args, "goal", "")))
    isempty(String(goal)) && error("goal required")
    g = goal_info(goal)
    return Dict(
        "id" => string(g.id),
        "name" => g.name,
        "description" => g.description,
        "recommended_study" => string(g.recommended_study),
        "metrics" => string.(g.recommended_metrics),
        "traffic" => string.(g.recommended_traffic),
        "routing" => string.(g.recommended_routing),
        "topology" => string.(g.recommended_topology),
        "constellation" => string.(g.recommended_constellation),
    )
end

function _symbolize_keys(d::AbstractDict)
    out = Dict{Symbol,Any}()
    for (k, v) in d
        out[Symbol(String(k))] = v isa AbstractString ? Symbol(v) : v
    end
    return out
end

function _plan_summary(plan::StudyPlan)
    return Dict(
        "goal" => string(plan.goal),
        "study_type" => string(plan.study_type),
        "parameters" => Dict(string(k) => string(v) for (k, v) in plan.parameters),
    )
end

function _tool_plan_study(args::AbstractDict)
    goal = Symbol(String(get(args, "goal", "")))
    isempty(String(goal)) && error("goal required")
    answers = haskey(args, "answers") ? _symbolize_keys(args["answers"]) : Dict{Symbol,Any}()
    answers[:goal] = goal
    return _plan_summary(create_plan(answers))
end

function _study_tool_tspan(args::AbstractDict)
    has_duration = haskey(args, "duration_s")
    has_steps = haskey(args, "steps")
    (has_duration || has_steps) || return nothing
    duration = Float64(get(args, "duration_s", 600))
    steps = max(1, Int(get(args, "steps", 2)))
    return collect(range(0.0, duration; length = steps))
end

function _first_successful_case(run::StudyRunResult)
    for case_result in run.cases
        case_result.status === :succeeded && case_result.result !== nothing && return case_result
    end
    return nothing
end

function _tool_run_study_plan(args::AbstractDict)
    goal = Symbol(String(get(args, "goal", "")))
    isempty(String(goal)) && error("goal required")
    answers = haskey(args, "answers") ? _symbolize_keys(args["answers"]) : Dict{Symbol,Any}()
    answers[:goal] = goal
    ground_stations = _parse_ai_ground_stations(get(args, "ground_stations", get(answers, :ground_stations, [])))
    ground_pairs = _parse_ai_ground_pairs(get(args, "ground_pairs", get(answers, :ground_pairs, [])), ground_stations)
    max_cases = Int(get(args, "max_cases", 8))
    tspan = _study_tool_tspan(args)
    plan = create_plan(answers)
    run = run_study_plan(plan;
        ground_stations = ground_stations,
        ground_pairs = ground_pairs,
        max_cases = max_cases,
        tspan = tspan,
    )
    manifest = study_run_manifest(run)
    first_case = _first_successful_case(run)
    result = first_case === nothing ? nothing : first_case.result
    base = Dict{String,Any}(
        "plan" => _plan_summary(plan),
        "summary_scope" => "representative_first_successful_case",
        "case_count" => length(run.cases),
        "manifest" => manifest,
        "artifacts" => manifest["artifacts"],
        "status" => manifest["status"],
    )
    if result === nothing
        base["error"] = "no successful study cases"
        return base
    end
    traffic_evaluation = result.traffic_evaluation
    traffic_totals = _traffic_assignment_totals(traffic_evaluation)
    merge!(base, Dict{String,Any}(
        "coverage_ratio" => round(result.coverage.coverage_ratio, digits=4),
        "avg_latency_ms" => round(result.latency.avg_latency_ms, digits=2),
        "connectivity_ratio" => round(result.network.connectivity_ratio, digits=4),
        "fitness" => round(result.fitness, digits=4),
        "traffic_demands" => length(result.config.traffic_demands),
        "ground_stations" => length(result.config.ground_stations),
        "ground_pairs" => length(result.config.ground_pairs),
        "traffic_evaluation_ran" => traffic_evaluation !== nothing,
        "traffic_fallback" => !isempty(result.config.traffic_demands) && traffic_evaluation === nothing,
        "traffic_time_steps" => traffic_evaluation === nothing ? 0 : length(traffic_evaluation.assignments_by_time),
        "traffic_assignments" => traffic_evaluation === nothing ? 0 : sum(length, traffic_evaluation.assignments_by_time),
        "offered_mbps" => round(traffic_totals.offered_mbps, digits=3),
        "carried_mbps" => round(traffic_totals.carried_mbps, digits=3),
        "dropped_mbps" => round(traffic_totals.dropped_mbps, digits=3),
    ))
    return base
end

function register_planner_ai_tools!()
    register_ai_tool!(AIToolSpec(
        "list_goals",
        "列出可用研究目标。",
        Dict{String,Any}("type" => "object", "properties" => Dict{String,Any}()),
        _tool_list_goals,
    ))
    register_ai_tool!(AIToolSpec(
        "describe_goal",
        "查看某个研究目标的说明和推荐配置。",
        Dict{String,Any}(
            "type" => "object",
            "properties" => Dict{String,Any}("goal" => Dict("type" => "string")),
            "required" => ["goal"],
        ),
        _tool_describe_goal,
    ))
    register_ai_tool!(AIToolSpec(
        "plan_study",
        "根据 goal 和 answers 生成 StudyPlan 摘要。",
        Dict{String,Any}(
            "type" => "object",
            "properties" => Dict{String,Any}(
                "goal" => Dict("type" => "string"),
                "answers" => Dict("type" => "object"),
            ),
            "required" => ["goal"],
        ),
        _tool_plan_study,
    ))
    register_ai_tool!(AIToolSpec(
        "run_study_plan",
        "根据 goal 和 answers 创建 Study 并运行一次实验。",
        Dict{String,Any}(
            "type" => "object",
            "properties" => Dict{String,Any}(
                "goal" => Dict("type" => "string"),
                "answers" => Dict("type" => "object"),
                "max_cases" => Dict("type" => "integer", "default" => 8, "description" => "最多展开并执行的 StudyRun case 数。"),
                "duration_s" => Dict("type" => "number", "description" => "可选短仿真时长；提供后与 steps 一起生成 tspan。"),
                "steps" => Dict("type" => "integer", "description" => "可选采样步数；提供后与 duration_s 一起生成 tspan。"),
                "ground_stations" => Dict(
                    "type" => "array",
                    "items" => Dict(
                        "type" => "object",
                        "properties" => Dict(
                            "id" => Dict("type" => "integer"),
                            "name" => Dict("type" => "string"),
                            "lat" => Dict("type" => "number"),
                            "lon" => Dict("type" => "number"),
                            "alt_km" => Dict("type" => "number"),
                        ),
                        "required" => ["lat", "lon"],
                    ),
                ),
                "ground_pairs" => Dict(
                    "type" => "array",
                    "items" => Dict(
                        "type" => "array",
                        "items" => Dict("type" => "integer"),
                    ),
                ),
            ),
            "required" => ["goal"],
        ),
        _tool_run_study_plan,
    ))
    return nothing
end

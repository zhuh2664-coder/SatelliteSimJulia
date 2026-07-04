# ===== Questionnaire system =====

export Question, Questionnaire, build_questionnaire, answer_questionnaire

struct Question
    id::Symbol
    text::String
    kind::Symbol
    options::Vector
    default::Any
end

struct Questionnaire
    goal::Symbol
    title::String
    questions::Vector{Question}
end

function _common_questions(goal::Symbol)
    g = goal_info(goal)
    return [
        Question(:constellation_coverage, "选择覆盖目标？", :choice,
                 collect(keys(COVERAGE_TARGETS)), first(g.recommended_constellation)[1]),
        Question(:constellation_latency, "选择时延层级？", :choice,
                 collect(keys(LATENCY_TIERS)), first(g.recommended_constellation)[2]),
        Question(:constellation_scale, "选择星座规模？", :choice,
                 collect(keys(CONSTELLATION_SCALES)), first(g.recommended_constellation)[3]),
        Question(:topology_intent, "选择拓扑意图？", :choice,
                 collect(keys(TOPLOGY_INTENTS)), first(g.recommended_topology)),
        Question(:traffic_intent, "选择流量意图？", :choice,
                 collect(keys(TRAFFIC_INTENTS)), :uniform),
        Question(:metrics, "选择指标？", :multi_choice,
                 g.recommended_metrics, g.recommended_metrics),
    ]
end

function build_questionnaire(goal::Symbol)
    g = goal_info(goal)
    return Questionnaire(goal, g.name, vcat(_common_questions(goal), _specific_questions(goal)))
end

function _specific_questions(goal::Symbol)
    if goal == :routing_comparison
        g = goal_info(goal)
        return [
            Question(:algorithms, "比较哪些路由算法？", :multi_choice,
                     g.recommended_routing, g.recommended_routing),
        ]
    elseif goal == :constellation_comparison
        return [
            Question(:constellations, "比较哪些构型？", :multi_choice,
                     SatelliteSimCore.list_constellations(), [:walker24, :walker48]),
        ]
    elseif goal == :capacity_analysis
        return [
            Question(:user_counts, "扫描什么用户规模？", :free,
                     [100, 500, 1000, 2000], [100, 500, 1000]),
        ]
    elseif goal == :coverage_analysis
        return [
            Question(:lat_bounds, "关注什么纬度范围？", :free,
                     [(-70.0, 70.0), (-90.0, 90.0)], (-70.0, 70.0)),
        ]
    elseif goal == :cache_analysis
        return [
            Question(:storage_range, "扫描什么缓存容量（GB）？", :free,
                     [100.0, 500.0, 1000.0], [100.0, 500.0, 1000.0]),
        ]
    else
        return Question[]
    end
end

function answer_questionnaire(q::Questionnaire)
    println("\n=== $(q.title) ===\n")
    answers = Dict{Symbol,Any}(:goal => q.goal)
    for qn in q.questions
        println("$(qn.text)")
        if qn.kind == :choice
            for (i, opt) in enumerate(qn.options)
                println("  $i. $opt")
            end
            print("选择 [默认: $(qn.default)]: ")
            input = String(strip(readline()))
            answers[qn.id] = isempty(input) ? qn.default : qn.options[parse(Int, input)]
        elseif qn.kind == :multi_choice
            for (i, opt) in enumerate(qn.options)
                println("  $i. $opt")
            end
            print("选择（逗号分隔）[默认: $(qn.default)]: ")
            input = String(strip(readline()))
            if isempty(input)
                answers[qn.id] = qn.default
            else
                indices = parse.(Int, split(input, ","))
                answers[qn.id] = [qn.options[i] for i in indices]
            end
        else
            print("输入 [默认: $(qn.default)]: ")
            input = String(strip(readline()))
            answers[qn.id] = isempty(input) ? qn.default : input
        end
        println()
    end
    return answers
end

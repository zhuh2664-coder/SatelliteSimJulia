# ===== Ground-satellite access decisions =====

export AccessDecision, AccessDecisionTable,
       access_decisions_at, access_decisions_for_ground,
       ground_ids, build_access_decision_table

struct AccessDecision
    ground_id::Int
    time_index::Int
    selected_satellite_id::Union{Nothing,Int}
    selected_sample::Union{Nothing,GSLPhysicalLinkSample}

    function AccessDecision(;
        ground_id::Int,
        time_index::Int,
        selected_satellite_id::Union{Nothing,Int},
        selected_sample::Union{Nothing,GSLPhysicalLinkSample},
    )
        ground_id > 0 || throw(ArgumentError("ground_id must be positive"))
        time_index > 0 || throw(ArgumentError("time_index must be positive"))
        selected_satellite_id === nothing || selected_satellite_id > 0 ||
            throw(ArgumentError("selected_satellite_id must be positive when provided"))
        if selected_sample !== nothing
            selected_sample.ground_id == ground_id ||
                throw(ArgumentError("selected_sample ground_id must match the decision"))
            selected_sample.time_index == time_index ||
                throw(ArgumentError("selected_sample time_index must match the decision"))
            selected_satellite_id == selected_sample.satellite_id ||
                throw(ArgumentError("selected_satellite_id must match selected_sample"))
        end
        return new(ground_id, time_index, selected_satellite_id, selected_sample)
    end
end

AccessDecision(ground_id::Int, time_index::Int) = AccessDecision(
    ground_id=ground_id,
    time_index=time_index,
    selected_satellite_id=nothing,
    selected_sample=nothing,
)

struct AccessDecisionTable
    time_grid::SimulationTimeGrid
    decisions_by_ground::Dict{Int,Vector{AccessDecision}}

    function AccessDecisionTable(
        time_grid::SimulationTimeGrid,
        decisions_by_ground::Dict{Int,Vector{AccessDecision}},
    )
        expected_count = time_count(time_grid)
        for (ground_id, decisions) in decisions_by_ground
            ground_id > 0 || throw(ArgumentError("ground ids must be positive"))
            length(decisions) == expected_count ||
                throw(ArgumentError("each ground endpoint must have one decision per time slice"))
            for (time_index, decision) in pairs(decisions)
                decision.ground_id == ground_id ||
                    throw(ArgumentError("decision ground_id must match table key"))
                decision.time_index == time_index ||
                    throw(ArgumentError("decision time_index must match time slice order"))
            end
        end
        return new(time_grid, decisions_by_ground)
    end
end

function access_decisions_at(
    table::AccessDecisionTable,
    ground_id::Int,
    time_index::Int,
)::AccessDecision
    decisions = get(table.decisions_by_ground, ground_id, nothing)
    decisions === nothing && return AccessDecision(ground_id, time_index)
    return decisions[time_index]
end

function access_decisions_for_ground(
    table::AccessDecisionTable,
    ground_id::Int,
)::Vector{AccessDecision}
    return get(table.decisions_by_ground, ground_id, AccessDecision[])
end

ground_ids(table::AccessDecisionTable)::Vector{Int} = sort(collect(keys(table.decisions_by_ground)))

function _best_access_sample(samples::Vector{GSLPhysicalLinkSample})::Union{Nothing,GSLPhysicalLinkSample}
    return select_satellite(ElevationThreshold(), samples)
end

function build_access_decision_table(
    gsl_series_by_ground::Vector{GSLPhysicalLinkSeries},
)::AccessDecisionTable
    !isempty(gsl_series_by_ground) || throw(ArgumentError("gsl_series_by_ground must not be empty"))
    time_grid = first(gsl_series_by_ground).time_grid
    decisions_by_ground = Dict{Int,Vector{AccessDecision}}()

    for series in gsl_series_by_ground
        series.time_grid === time_grid ||
            throw(ArgumentError("all GSL series must share the same time_grid object"))
        decisions = AccessDecision[]
        for time_index in 1:time_count(time_grid)
            sample = _best_access_sample(available_gsl_samples(series, time_index))
            selected_satellite_id = sample === nothing ? nothing : sample.satellite_id
            push!(
                decisions,
                AccessDecision(
                    ground_id=series.ground_id,
                    time_index=time_index,
                    selected_satellite_id=selected_satellite_id,
                    selected_sample=sample,
                ),
            )
        end
        decisions_by_ground[series.ground_id] = decisions
    end

    return AccessDecisionTable(time_grid, decisions_by_ground)
end

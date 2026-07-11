# ===== Experiment state =====

export ExperimentState

mutable struct ExperimentState
    step::Int
    positions::AbstractArray{<:Real,3}
    isl_links::Vector{Tuple{Int,Int}}
    gsl_available::Matrix{Bool}
    distance_matrix::Matrix{Float64}
    metrics::Dict{String,Float64}
end

function ExperimentState()
    return ExperimentState(
        0,
        zeros(0, 0, 0),
        Tuple{Int,Int}[],
        zeros(Bool, 0, 0),
        zeros(0, 0),
        Dict{String,Float64}(),
    )
end

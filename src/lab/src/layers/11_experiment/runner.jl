# ===== Experiment runner =====

export run_experiment, run_multiframe_experiment

function _last_position_matrix(positions::AbstractArray{<:Real,3})::AbstractMatrix{<:Real}
    return positions_at_last(positions)
end

function _user_position_tuples(users::Vector{GroundUser})::Vector{NTuple{3,Float64}}
    return [(u.lat, u.lon, 0.0) for u in users]
end

function _default_pairs(T::Int, n::Int)::Vector{Tuple{Int,Int}}
    return [(i, mod1(i + div(T, 2), T)) for i in 1:min(n, T)]
end

function run_experiment(config::ExperimentConfig)::ExperimentResult
    # run_experiment 现在是 full_constellation_assessment 的薄壳。
    # 核心逻辑已提取到 precomposed.jl 作为预编排工具，
    # 用户/AI 也可单独调 assess_coverage / assess_routing 等更细粒度的组合。
    return full_constellation_assessment(config)
end

function run_multiframe_experiment(config::ExperimentConfig)
    t_start = time()

    constellation = config.constellation
    T = constellation.T
    P = constellation.P

    _, positions = propagate_constellation_positions(config)

    n_sat = T
    n_time = size(positions, 2)
    dt_s = length(config.tspan) > 1 ? config.tspan[2] - config.tspan[1] : 1.0
    user_tuples = _user_position_tuples(config.users)
    isempty(user_tuples) && error("run_multiframe_experiment requires at least one user")

    gsl_series = Array{Bool,3}(undef, n_sat, n_time, length(user_tuples))
    for t in 1:n_time
        pos_t = position_at_instant(positions, t)
        gsl_series[:, t, :] = evaluate_gsl_batch(pos_t, user_tuples; constraints=config.constraints)[1]
    end

    result = compute_temporal_coverage(gsl_series, Float64(dt_s))
    println(
        "多帧实验完成: $(round(time() - t_start, digits=1))s, ",
        "$(n_time) 帧, $(length(user_tuples)) 地面站, $(n_sat) 颗星",
    )
    return result
end

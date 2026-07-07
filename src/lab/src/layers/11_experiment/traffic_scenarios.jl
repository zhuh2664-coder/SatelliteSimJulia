# ===== Traffic scenario helpers =====

export all_to_all_pairs, city_to_city_pairs, city_to_city_pairs_sampled,
       run_dynamic_ground_traffic_scenario, traffic_evaluation_summary

function all_to_all_pairs(T::Int)
    pairs = Tuple{Int,Int}[]
    sizehint!(pairs, div(T * (T - 1), 2))
    for i in 1:T
        for j in (i + 1):T
            push!(pairs, (i, j))
        end
    end
    return pairs
end

function _city_lat_lon_alt(city)
    if city isa AbstractDict
        lat = parse(Float64, string(get(city, "lat", get(city, :lat, get(city, "latitude", get(city, :latitude, ""))))))
        lon = parse(Float64, string(get(city, "lon", get(city, :lon, get(city, "longitude", get(city, :longitude, ""))))))
        alt = parse(Float64, string(get(city, "alt", get(city, :alt, get(city, "altitude", get(city, :altitude, 0.0))))))
        return (lat, lon, alt)
    end

    if hasproperty(city, :position)
        pos = getproperty(city, :position)
        return (pos.latitude_deg, pos.longitude_deg, pos.altitude_km)
    end

    lat = hasproperty(city, :lat) ? getproperty(city, :lat) : getproperty(city, :latitude)
    lon = hasproperty(city, :lon) ? getproperty(city, :lon) : getproperty(city, :longitude)
    alt = hasproperty(city, :alt) ? getproperty(city, :alt) :
          hasproperty(city, :altitude) ? getproperty(city, :altitude) :
          hasproperty(city, :elevation) ? getproperty(city, :elevation) / 1000 : 0.0
    return (Float64(lat), Float64(lon), Float64(alt))
end

function city_to_city_pairs(
    sat_positions::Matrix{Float64},
    cities::Vector,
    constraints::PhysicalConstraints=LEO_DEFAULTS;
    top_k::Int=3,
    city_pairs::Union{Nothing,Vector{Tuple{Int,Int}}}=nothing,
)
    n_cities = length(cities)
    T = size(sat_positions, 1)

    city_visible_sats = Vector{Vector{Int}}(undef, n_cities)
    for (ci, city) in enumerate(cities)
        city_tup = _city_lat_lon_alt(city)
        avail, dist, _, _ = evaluate_gsl_batch(sat_positions, [city_tup]; constraints=constraints)
        visible = Tuple{Int,Float64}[]
        for i in 1:T
            avail[i, 1] || continue
            push!(visible, (i, dist[i, 1]))
        end
        sort!(visible, by=x -> x[2])
        k = min(top_k, length(visible))
        city_visible_sats[ci] = [visible[j][1] for j in 1:k]
    end

    cp = if city_pairs === nothing
        pairs = Tuple{Int,Int}[]
        for i in 1:n_cities
            for j in (i + 1):n_cities
                push!(pairs, (i, j))
            end
        end
        pairs
    else
        city_pairs
    end

    gs_pairs = Tuple{Int,Int}[]
    for (ci, cj) in cp
        vi = city_visible_sats[ci]
        vj = city_visible_sats[cj]
        (isempty(vi) || isempty(vj)) && continue
        for si in vi, sj in vj
            si == sj && continue
            push!(gs_pairs, (si, sj))
        end
    end
    return gs_pairs
end

function city_to_city_pairs_sampled(
    sat_positions::Matrix{Float64},
    cities::Vector,
    constraints::PhysicalConstraints=LEO_DEFAULTS;
    top_k::Int=3,
    n_pairs::Int=15,
    n_sample::Int=10,
)
    n_cities = length(cities)
    n_pairs = min(n_pairs, div(n_cities * (n_cities - 1), 2))
    sampled = Set{Tuple{Int,Int}}()
    attempts = 0
    max_attempts = max(10, 10 * n_sample)
    while length(sampled) < n_sample && attempts < max_attempts
        attempts += 1
        pool = sample_pairs(n_pairs, n_cities)
        gs_pairs = city_to_city_pairs(
            sat_positions,
            cities,
            constraints;
            top_k=top_k,
            city_pairs=pool,
        )
        union!(sampled, gs_pairs)
    end
    return collect(sampled)
end

function sample_pairs(n::Int, total::Int)
    pairs = Tuple{Int,Int}[]
    seen = Set{Tuple{Int,Int}}()
    while length(pairs) < n
        i = rand(1:total)
        j = rand(1:total)
        i == j && continue
        p = i < j ? (i, j) : (j, i)
        p in seen && continue
        push!(seen, p)
        push!(pairs, p)
    end
    return pairs
end

"""
    run_dynamic_ground_traffic_scenario(config; strategy_builder, positions, demands, routing_algorithm)

显式 scenario runner：用 `ExperimentConfig` 调正式 ground-end-to-end 动态流量入口。
默认保持 `run_experiment(config)` 旧语义不变；需要这个场景时显式调用本函数。
"""
function run_dynamic_ground_traffic_scenario(
    config::ExperimentConfig;
    strategy_builder::Function = _ -> config.topology_strategy,
    positions = nothing,
    demands = config.traffic_demands,
    routing_algorithm = config.routing_algorithm,
    constellation_name::String = string(config.name, "-ground-traffic"),
)
    isempty(config.ground_stations) && throw(ArgumentError(
        "run_dynamic_ground_traffic_scenario requires ground_stations",
    ))
    isempty(demands) && throw(ArgumentError(
        "run_dynamic_ground_traffic_scenario requires non-empty traffic demands",
    ))
    positions_matrix = if positions === nothing
        _, propagated = propagate_constellation_positions(config)
        propagated
    else
        positions
    end
    return assess_ground_traffic_temporal_dynamic(
        positions_matrix,
        config.constellation.T,
        config.constellation.P,
        strategy_builder,
        config.constraints,
        config.ground_stations,
        demands;
        elapsed_by_time = config.tspan,
        routing_algorithm = routing_algorithm,
        constellation_name = constellation_name,
    )
end

function traffic_evaluation_summary(evaluation)
    assignments = reduce(vcat, evaluation.assignments_by_time; init = Any[])
    loads = reduce(vcat, evaluation.link_loads_by_time; init = Any[])
    isl_loads = filter(load -> load.link_type == :isl, loads)
    gsl_loads = filter(load -> load.link_type == :gsl, loads)
    return (
        n_times = length(evaluation.assignments_by_time),
        n_assignments = length(assignments),
        n_reachable = count(assignment -> assignment.route.reachable, assignments),
        offered_mbps = sum(assignment -> assignment.offered_mbps, assignments; init = 0.0),
        carried_mbps = sum(assignment -> assignment.carried_mbps, assignments; init = 0.0),
        dropped_mbps = sum(assignment -> assignment.dropped_mbps, assignments; init = 0.0),
        max_isl_utilization = isempty(isl_loads) ? 0.0 : maximum(load -> load.utilization, isl_loads),
        max_gsl_utilization = isempty(gsl_loads) ? 0.0 : maximum(load -> load.utilization, gsl_loads),
    )
end

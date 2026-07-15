# ===== 预编排工具 =====
#
# 这些函数是"常用组合"——把原子工具按典型流程串起来。
# 它们是开发者根据使用经验封装的便利组件，给不想从零搭管线的客户用。
#
# 设计原则：
#   - 内部只调原子工具，不引入新物理实现（单一真相源）
#   - 用户可以调预编排工具（省事），也可以拆开调原子工具（灵活）
#   - 数据用标准结构衔接：Array{Float64,3} 位置、Vector{NamedTuple} ISL 结果等
#
# 三层架构定位：
#   第一层（工具）：原子工具 + 本文件的预编排工具
#   第二层（编排）：用户/AI 自由组合这些工具；run_experiment 是其中一个示例组合
#   第三层（AI）：把需求翻译成"调哪个工具/工具组合"

using SatelliteSimCore
using SatelliteSimNet
using SatelliteSimTraffic: TrafficDemand, LinkLoadSample, TrafficEvaluation, evaluate_traffic_from_bare_arrays
import Random
# 从 Foundation 借时间网格（Core re-export 了 Foundation，但 SimulationTimeGrid 需要显式引用）
import SatelliteSimFoundation: SimulationTimeGrid, default_starlink_simulation_epoch

export propagate_constellation_positions, assess_coverage, assess_routing,
       assess_routing_temporal, assess_routing_temporal_dynamic,
       assess_temporal_flow_routes, assess_ground_traffic_temporal_dynamic,
       full_constellation_assessment

# ────────────────────────────────────────────────────────────
# 基础组合：星座生成 + 传播 → 位置矩阵
# ────────────────────────────────────────────────────────────

"""
    propagate_constellation_positions(config) -> (elems, positions)

预编排：Walker 星座生成 → 轨道传播 → 位置矩阵 (N×T×3)。

这是几乎所有评估的公共前置步骤。
返回 KeplerianElements 列表和 ECEF 位置矩阵。
"""
function propagate_constellation_positions(config)
    constellation = config.constellation
    elems = generate_walker_delta(;
        T = constellation.T, P = constellation.P, F = constellation.F,
        alt_km = constellation.alt_km, inc_deg = constellation.inc_deg,
    )
    positions = if config.orbit_backend === nothing
        propagate_to_ecef(elems, config.tspan; propagator = config.propagator)
    else
        backend = create_orbit_backend(config.orbit_backend)
        propagate_to_ecef(backend, elems, config.tspan)
    end
    return elems, positions
end

# ────────────────────────────────────────────────────────────
# 覆盖评估：位置 → GSL → 覆盖率
# ────────────────────────────────────────────────────────────

"""
    assess_coverage(positions, users, constraints) -> (gsl_available, coverage)

预编排：位置矩阵 → GSL 批评估 → 覆盖率计算。

输入：
- `positions::Array{Float64,3}`：N×T×3 ECEF 位置
- `users::Vector{GroundUser}`：地面用户列表
- `constraints::PhysicalConstraints`：物理约束

返回 GSL 可用矩阵和覆盖结果。
"""
function assess_coverage(positions::Array{Float64,3}, users, constraints)
    n_sat = n_satellites(positions)
    user_tuples = [(u.lat, u.lon, 0.0) for u in users]
    gsl_available = isempty(user_tuples) ?
        zeros(Bool, n_sat, 0) :
        evaluate_gsl_batch(positions_at_last(positions), user_tuples; constraints = constraints)[1]
    coverage = compute_coverage(gsl_available, [u.id for u in users])
    return gsl_available, coverage
end

# ────────────────────────────────────────────────────────────
# 路由评估：位置 → 拓扑 → ISL → 路由 → 时延/连通性
# ────────────────────────────────────────────────────────────

"""
    assess_routing(positions, T, P, strategy, constraints) -> (D, available_isl, isl_results)

预编排：位置 → 拓扑生成 → ISL 批评估 → 邻接表 → 全对最短路径。

输入：
- `positions::Array{Float64,3}`：N×T×3 ECEF 位置
- `T::Int, P::Int`：卫星总数和轨道面数
- `strategy`：拓扑策略（如 GridPlusStrategy()）
- `constraints`：物理约束

返回距离矩阵 D、可用 ISL 列表、ISL 评估结果。
"""
function _topology_isl_candidates(strategy, T::Int, P::Int)
    topo_output = generate_topology(strategy, T, P)
    return vcat(topo_output.static_links, topo_output.dynamic_candidates)
end

function assess_routing(
    positions::Array{Float64,3}, T::Int, P::Int,
    strategy, constraints,
)
    last_pos = positions_at_last(positions)
    all_links = _topology_isl_candidates(strategy, T, P)

    isl_results = evaluate_isl_batch(last_pos, all_links; constraints = constraints)

    available_isl = Tuple{Int,Int}[
        (Int(all_links[i][1]), Int(all_links[i][2]))
        for (i, result) in enumerate(isl_results) if result.available
    ]

    if isempty(available_isl)
        D = fill(Inf, T, T)
        for i in 1:T; D[i, i] = 0.0; end
    else
        weights = Float64[r.latency_ms for r in isl_results if r.available]
        adjacency = build_adjacency(T, available_isl, weights)
        D = all_pairs_shortest_paths(adjacency)
    end

    return D, available_isl, isl_results
end

# ────────────────────────────────────────────────────────────
# 时序路由评估：多时间步距离矩阵演化
# ────────────────────────────────────────────────────────────

"""
    assess_routing_temporal(positions, T, P, strategy, constraints) -> Vector{Matrix{Float64}}

预编排：对所有时间步算路由距离矩阵，返回时序 D 序列。

解决痛点：assess_routing 只取最后帧（positions_at_last），看不到路由随时间的演化。
这个函数对每个时间步都算 ISL + 最短路径，产出 D[t] 序列，可用于：
- 时延随时间变化曲线
- 连通性中断检测
- 路由稳定性分析

返回 Vector{Matrix{Float64}}，第 t 个元素是第 t 个时间步的距离矩阵。
"""
function assess_routing_temporal(
    positions::Array{Float64,3}, T::Int, P::Int,
    strategy, constraints,
)
    n_time = n_timesteps(positions)
    topo_output = generate_topology(strategy, T, P)
    all_links = vcat(topo_output.static_links, topo_output.dynamic_candidates)

    D_series = Vector{Matrix{Float64}}(undef, n_time)

    for t in 1:n_time
        pos_t = position_at_instant(positions, t)
        isl_results = evaluate_isl_batch(pos_t, all_links; constraints = constraints)

        available_isl = Tuple{Int,Int}[
            (Int(all_links[i][1]), Int(all_links[i][2]))
            for (i, result) in enumerate(isl_results) if result.available
        ]

        if isempty(available_isl)
            D = fill(Inf, T, T)
            for i in 1:T; D[i, i] = 0.0; end
        else
            weights = Float64[r.latency_ms for r in isl_results if r.available]
            adjacency = build_adjacency(T, available_isl, weights)
            D = all_pairs_shortest_paths(adjacency)
        end
        D_series[t] = D
    end

    return D_series
end

"""
    assess_routing_temporal_dynamic(positions, T, P, strategy_builder, constraints) -> Vector{Matrix{Float64}}

预编排：对每个时间步重新生成拓扑，再计算该帧的路由距离矩阵。

`strategy_builder(t)` 必须返回一个拓扑策略。这个入口用于动态候选链路
随时间变化的策略，例如 `NearestNeighborStrategy(positions=positions, time_step=t)`。
旧的 `assess_routing_temporal` 保持固定拓扑语义；本函数是并行新增入口。
"""
function assess_routing_temporal_dynamic(
    positions::Array{Float64,3}, T::Int, P::Int,
    strategy_builder::Function, constraints,
)
    n_time = n_timesteps(positions)
    D_series = Vector{Matrix{Float64}}(undef, n_time)

    for t in 1:n_time
        strategy = strategy_builder(t)
        topo_output = generate_topology(strategy, T, P)
        all_links = vcat(topo_output.static_links, topo_output.dynamic_candidates)
        pos_t = position_at_instant(positions, t)
        isl_results = evaluate_isl_batch(pos_t, all_links; constraints = constraints)

        available_isl = Tuple{Int,Int}[
            (Int(all_links[i][1]), Int(all_links[i][2]))
            for (i, result) in enumerate(isl_results) if result.available
        ]

        if isempty(available_isl)
            D = fill(Inf, T, T)
            for i in 1:T; D[i, i] = 0.0; end
        else
            weights = Float64[r.latency_ms for r in isl_results if r.available]
            adjacency = build_adjacency(T, available_isl, weights)
            D = all_pairs_shortest_paths(adjacency)
        end

        D_series[t] = D
    end

    return D_series
end

"""
    assess_temporal_flow_routes(positions, T, P, strategy_builder, constraints, demands, algorithm; elapsed_by_time)

预编排：每个时间步重新生成拓扑，并对活跃 `TrafficDemand` 做逐流路由。

这是**卫星节点级 probe**：`TrafficDemand.source_ground_id` /
`destination_ground_id` 在这里必须已经是卫星节点 id，且必须落在 `1:T`。
它只用于低成本验证动态拓扑、活跃时间窗和 Net 路由分派，不走 GSL access、
`AccessDecisionTable` 或 Traffic AON，也不证明 ground-end-to-end MinLoad 负载均衡。

正式地面端到端流量实验请使用 `assess_ground_traffic_temporal_dynamic`，它会
通过 `evaluate_traffic_from_bare_arrays` 返回 `TrafficEvaluation`。
"""
function assess_temporal_flow_routes(
    positions::Array{Float64,3}, T::Int, P::Int,
    strategy_builder::Function, constraints,
    demands::Vector{TrafficDemand}, algorithm;
    elapsed_by_time = collect(0:(n_timesteps(positions)-1)),
)
    n_time = n_timesteps(positions)
    length(elapsed_by_time) == n_time ||
        throw(ArgumentError("elapsed_by_time length must match positions time dimension"))
    _validate_satellite_node_demands(demands, T)

    frames = Vector{NamedTuple}(undef, n_time)

    for t in 1:n_time
        strategy = strategy_builder(t)
        topo_output = generate_topology(strategy, T, P)
        all_links = vcat(topo_output.static_links, topo_output.dynamic_candidates)
        pos_t = position_at_instant(positions, t)
        isl_results = evaluate_isl_batch(pos_t, all_links; constraints = constraints)

        available_isl = Tuple{Int,Int}[
            (Int(all_links[i][1]), Int(all_links[i][2]))
            for (i, result) in enumerate(isl_results) if result.available
        ]
        weights = Float64[result.latency_ms for result in isl_results if result.available]
        graph = routing_graph_from_edges(T, available_isl, weights)

        elapsed_s = Int(round(elapsed_by_time[t]))
        active_demands = TrafficDemand[
            demand for demand in demands
            if demand.start_elapsed_s <= elapsed_s < demand.end_elapsed_s
        ]
        routes = RoutingOutput[
            route(algorithm, RoutingInput(
                graph,
                demand.source_ground_id,
                demand.destination_ground_id,
            ))
            for demand in active_demands
        ]
        link_loads = _link_load_samples_from_routes(
            available_isl,
            routes,
            active_demands,
            t,
            elapsed_s,
            hasproperty(constraints, :isl_max_capacity_mbps) ?
                getproperty(constraints, :isl_max_capacity_mbps) : Inf,
        )

        frames[t] = (
            time_index = t,
            elapsed_s = elapsed_s,
            available_isl = available_isl,
            weights = weights,
            active_demands = active_demands,
            routes = routes,
            link_loads = link_loads,
        )
    end

    return frames
end

"""
    assess_ground_traffic_temporal_dynamic(
        positions, T, P, strategy_builder, constraints, ground_stations, demands;
        elapsed_by_time, routing_algorithm, isl_capacity_mbps, gsl_capacity_mbps,
        constellation_name,
    ) -> TrafficEvaluation

正式地面端到端动态流量入口：每个时间步重新生成拓扑，使用 union ISL 保持
link id 稳定，构造 GSL access，再通过 Traffic bridge 进入 AON/MinLoad。

本函数只做薄编排，不复制 Traffic AON、MinLoad、GSL access 或 Net 路由逻辑。
当前 GSL 接入沿用 bridge 的 max-elevation 策略。
"""
function assess_ground_traffic_temporal_dynamic(
    positions::Array{Float64,3}, T::Int, P::Int,
    strategy_builder::Function, constraints,
    ground_stations::Vector{GroundStation},
    demands::Vector{TrafficDemand};
    elapsed_by_time = collect(0:(n_timesteps(positions)-1)),
    routing_algorithm = nothing,
    isl_capacity_mbps = hasproperty(constraints, :isl_max_capacity_mbps) ?
        getproperty(constraints, :isl_max_capacity_mbps) : 1000.0,
    gsl_capacity_mbps = hasproperty(constraints, :gsl_base_capacity_mbps) ?
        getproperty(constraints, :gsl_base_capacity_mbps) : 500.0,
    constellation_name::String = "lab-ground-traffic",
)::TrafficEvaluation
    n_time = n_timesteps(positions)
    length(elapsed_by_time) == n_time ||
        throw(ArgumentError("elapsed_by_time length must match positions time dimension"))
    isempty(ground_stations) && throw(ArgumentError("ground_stations must not be empty"))

    grid = _simulation_time_grid_from_tspan(Float64.(elapsed_by_time), n_time)
    grid === nothing && throw(ArgumentError(
        "elapsed_by_time must start at 0 and form a positive integer uniform grid",
    ))

    links_by_time = [
        _topology_links(strategy_builder(t), T, P)
        for t in 1:n_time
    ]
    isl_pairs = _stable_link_union(links_by_time)
    isl_results_by_time = [
        _isl_results_for_union(
            position_at_instant(positions, t),
            isl_pairs,
            links_by_time[t],
            constraints,
        )
        for t in 1:n_time
    ]

    gs_tuples = _ground_station_tuples(ground_stations)
    gsl_avail = Matrix{Bool}[]
    gsl_dist = Matrix{Float64}[]
    gsl_elev = Matrix{Float64}[]
    gsl_delay = Matrix{Float64}[]
    for t in 1:n_time
        a, d, e, delay = evaluate_gsl_batch(
            position_at_instant(positions, t),
            gs_tuples;
            constraints = constraints,
        )
        push!(gsl_avail, a)
        push!(gsl_dist, d)
        push!(gsl_elev, e)
        push!(gsl_delay, delay)
    end

    return evaluate_traffic_from_bare_arrays(
        positions,
        isl_pairs,
        isl_results_by_time,
        gsl_avail,
        gsl_dist,
        gsl_elev,
        _ground_station_ids(ground_stations),
        grid,
        demands;
        isl_capacity_mbps = Float64(isl_capacity_mbps),
        gsl_capacity_mbps = Float64(gsl_capacity_mbps),
        gsl_delay_ms_by_time = gsl_delay,
        constellation_name = constellation_name,
        routing_algorithm = routing_algorithm,
    )
end

function _validate_satellite_node_demands(demands::Vector{TrafficDemand}, T::Int)::Nothing
    for demand in demands
        if !(1 <= demand.source_ground_id <= T) || !(1 <= demand.destination_ground_id <= T)
            throw(ArgumentError(
                "assess_temporal_flow_routes is a satellite-node probe; demand endpoints " *
                "must be satellite ids in 1:$T. For ground endpoints/GSL/TrafficEvaluation, " *
                "use assess_ground_traffic_temporal_dynamic.",
            ))
        end
    end
    return nothing
end

_ground_station_ids(ground_stations::Vector{GroundStation}) = [station.id for station in ground_stations]

_ground_station_tuples(ground_stations::Vector{GroundStation}) = [
    (
        station.position.latitude_deg,
        station.position.longitude_deg,
        station.position.altitude_km,
    )
    for station in ground_stations
]

function _topology_links(strategy, T::Int, P::Int)::Vector{Tuple{Int,Int}}
    topo_output = generate_topology(strategy, T, P)
    return _normalize_isl_links(vcat(topo_output.static_links, topo_output.dynamic_candidates))
end

function _normalize_isl_links(links)::Vector{Tuple{Int,Int}}
    normalized = Tuple{Int,Int}[]
    for (src, dst) in links
        src_i = Int(src)
        dst_i = Int(dst)
        src_i == dst_i && continue
        push!(normalized, minmax(src_i, dst_i))
    end
    return sort(unique(normalized))
end

function _stable_link_union(links_by_time)::Vector{Tuple{Int,Int}}
    seen = Set{Tuple{Int,Int}}()
    for links in links_by_time
        union!(seen, links)
    end
    return sort(collect(seen))
end

function _isl_results_for_union(
    pos_t::Matrix{Float64},
    isl_pairs::Vector{Tuple{Int,Int}},
    active_links::Vector{Tuple{Int,Int}},
    constraints,
)
    results = evaluate_isl_batch(pos_t, isl_pairs; constraints = constraints)
    active = Set(active_links)
    return [
        isl_pairs[idx] in active ? result : _unavailable_isl_result(result)
        for (idx, result) in enumerate(results)
    ]
end

_unavailable_isl_result(result) = merge(result, (available = false, line_of_sight = false))

function _link_load_samples_from_routes(
    available_isl::Vector{Tuple{Int,Int}},
    routes::Vector{RoutingOutput},
    demands::Vector{TrafficDemand},
    time_index::Int,
    elapsed_s::Int,
    capacity_mbps::Real,
)::Vector{LinkLoadSample}
    length(routes) == length(demands) ||
        throw(ArgumentError("routes and demands must have the same length"))

    edge_index = Dict{Tuple{Int,Int},Int}()
    for (idx, (src, dst)) in enumerate(available_isl)
        edge_index[(src, dst)] = idx
        edge_index[(dst, src)] = idx
    end

    loads = Dict{Int,Float64}()
    for (route_output, demand) in zip(routes, demands)
        isfinite(route_output.total_weight) || continue
        path = route_output.path
        length(path) >= 2 || continue
        for hop in 1:length(path)-1
            link_id = get(edge_index, (path[hop], path[hop + 1]), nothing)
            link_id === nothing && continue
            loads[link_id] = get(loads, link_id, 0.0) + demand.rate_mbps
        end
    end

    return [
        begin
            src, dst = available_isl[link_id]
            LinkLoadSample(
                link_type = :isl,
                link_id = link_id,
                endpoint_a_id = src,
                endpoint_b_id = dst,
                time_index = time_index,
                elapsed_s = elapsed_s,
                load_mbps = load_mbps,
                capacity_mbps = capacity_mbps,
            )
        end
        for (link_id, load_mbps) in sort(collect(loads); by = first)
    ]
end

# ────────────────────────────────────────────────────────────
# 地面站接入辅助（路由/流量降级共用）
# ────────────────────────────────────────────────────────────

"""从 GroundStation 或带 lat/lon 字段的对象提取 (lat, lon, alt) 元组。"""
function _ground_station_tuple(gs)
    if hasproperty(gs, :position)
        pos = gs.position
        return (pos.latitude_deg, pos.longitude_deg, pos.altitude_km)
    elseif hasproperty(gs, :lat) && hasproperty(gs, :lon)
        alt = hasproperty(gs, :alt) ? Float64(gs.alt) :
              hasproperty(gs, :altitude) ? Float64(gs.altitude) : 0.0
        return (Float64(gs.lat), Float64(gs.lon), alt)
    end
    throw(ArgumentError("ground station must have position or lat/lon fields"))
end

"""
    _build_ground_access_map(positions, ground_stations, constraints)

为每个地面站 ID（1-based 枚举顺序）选取仰角最高的接入卫星及 GSL 时延（ms）。
"""
function _build_ground_access_map(positions, ground_stations, constraints)
    access_map = Dict{Int, NamedTuple{(:sat_id, :delay_ms), Tuple{Int, Float64}}}()
    isempty(ground_stations) && return access_map

    last_pos = positions_at_last(positions)
    for (gid, gs) in enumerate(ground_stations)
        tup = [_ground_station_tuple(gs)]
        avail, _, elev, delay = evaluate_gsl_batch(last_pos, tup; constraints=constraints)
        best_sat = 0
        best_elev = -Inf
        best_delay = Inf
        for sat_id in 1:size(last_pos, 1)
            if avail[sat_id, 1] && elev[sat_id, 1] > best_elev
                best_elev = elev[sat_id, 1]
                best_sat = sat_id
                best_delay = delay[sat_id, 1]
            end
        end
        best_sat > 0 && (access_map[gid] = (sat_id=best_sat, delay_ms=best_delay))
    end
    return access_map
end

"""解析路由端点对：返回 (pairs, use_ground)。"""
function _resolve_routing_endpoint_pairs(config, T::Int)
    if !isempty(config.ground_pairs)
        return config.ground_pairs, true
    elseif !isempty(config.ground_stations)
        n_gs = length(config.ground_stations)
        gs_ids = 1:n_gs
        pairs = [(a, b) for (k, a) in enumerate(gs_ids) for b in gs_ids[k+1:end]]
        return pairs, true
    else
        pairs = [(i, mod1(i + div(T, 2), T)) for i in 1:min(100, T)]
        return pairs, false
    end
end

"""在 ISL 邻接表上用 Dijkstra 重建卫星最短路径（返回节点序列）。"""
function _dijkstra_sat_path(src::Int, dst::Int, D, N::Int, edge_index::Dict{Tuple{Int,Int},Int})
    dist = fill(Inf, N)
    prev = zeros(Int, N)
    dist[src] = 0.0
    visited = falses(N)
    for _ in 1:N
        u = 0
        best = Inf
        for v in 1:N
            if !visited[v] && dist[v] < best
                best = dist[v]
                u = v
            end
        end
        u == 0 && break
        visited[u] = true
        u == dst && break
        for v in 1:N
            if !visited[v] && haskey(edge_index, (u, v)) && isfinite(D[u, v])
                alt = dist[u] + D[u, v]
                if alt < dist[v]
                    dist[v] = alt
                    prev[v] = u
                end
            end
        end
    end
    !isfinite(dist[dst]) && return Int[]
    path = Int[]
    v = dst
    while v != 0
        push!(path, v)
        v == src && break
        v = prev[v]
        v == 0 && return Int[]
    end
    return reverse(path)
end

"""地面站对路由：GSL + 配置路由算法 ISL 路径 + GSL。"""
function _route_ground_pair(
    src_g::Int, dst_g::Int, access_map, routing_graph, alg,
)
    label = string(typeof(alg).name.name)
    if !haskey(access_map, src_g) || !haskey(access_map, dst_g)
        return RoutingOutput(Int[], Inf, label * "-no-access")
    end
    routing_graph === nothing && return RoutingOutput(Int[], Inf, label * "-unreachable")
    src_sat = access_map[src_g].sat_id
    dst_sat = access_map[dst_g].sat_id
    isl_result = route(alg, RoutingInput(routing_graph, src_sat, dst_sat))
    isempty(isl_result.path) && return RoutingOutput(Int[], Inf, isl_result.algorithm * "-unreachable")
    total_ms = access_map[src_g].delay_ms + isl_result.total_weight + access_map[dst_g].delay_ms
    return RoutingOutput(isl_result.path, total_ms, isl_result.algorithm)
end

# ────────────────────────────────────────────────────────────
# 全套评估：覆盖 + 路由 + 容量 + 适应度
# ────────────────────────────────────────────────────────────

"""
    full_constellation_assessment(config) -> ExperimentResult

预编排：完整星座评估（覆盖 + 路由 + 利用率 + 适应度）。

这是 run_experiment 的核心逻辑提取——覆盖最常见的"全套评估"场景。
内部调用 propagate_constellation_positions + assess_coverage + assess_routing。
"""
function full_constellation_assessment(config)
    t_start = time()
    # 用 random_seed 播种 RNG，保证实验可复现（接通 random_seed 字段）
    Random.seed!(config.random_seed)
    constellation = config.constellation
    T = constellation.T
    P = constellation.P

    _, positions = propagate_constellation_positions(config)
    gsl_available, coverage = assess_coverage(positions, config.users, config.constraints)
    D, available_isl, isl_results = assess_routing(
        positions, T, P, config.topology_strategy, config.constraints,
    )
    traffic_isl_candidates = _topology_isl_candidates(config.topology_strategy, T, P)

    access_map = _build_ground_access_map(positions, config.ground_stations, config.constraints)

    latency = compute_latency(D)
    network = compute_network_metrics(D)

    # 路由结果：通过 RoutingGraph + config.routing_algorithm 逐对执行
    route_label = string(typeof(config.routing_algorithm).name.name)
    isl_weights = isempty(available_isl) ? Float64[] :
        Float64[r.latency_ms for r in isl_results if r.available]
    routing_graph = isempty(available_isl) ? nothing :
        build_routing_graph(T, available_isl, isl_weights)
    alg = config.routing_algorithm

    pairs, use_ground = _resolve_routing_endpoint_pairs(config, T)
    routing_results = RoutingOutput[]
    for (source, destination) in pairs
        if use_ground
            push!(routing_results, _route_ground_pair(
                source, destination, access_map, routing_graph, alg,
            ))
        elseif routing_graph === nothing
            push!(routing_results, RoutingOutput(
                Int[], Inf, string(typeof(alg).name.name) * "-unreachable",
            ))
        else
            push!(routing_results, route(alg, RoutingInput(routing_graph, source, destination)))
        end
    end

    n_isl = length(available_isl)
    # 流量评估：尝试完整 AON（多时间步），失败则降级到占位（向后兼容）。
    # AON 必须接收完整拓扑候选边，而不是 assess_routing 在最后一帧过滤出的
    # available_isl；否则早期可用但最后一帧不可用的链路会被整段漏评估。
    traffic_evaluation = nothing
    link_loads = if !isempty(traffic_isl_candidates) && !isempty(config.traffic_demands)
        traffic_evaluation = try
            _evaluate_traffic_full(config, positions, traffic_isl_candidates)
        catch
            nothing  # 降级
        end
        if traffic_evaluation === nothing
            # 降级：经地面接入卫星映射后再走 ISL 最短路径
            _assign_demands_to_isls(
                config.traffic_demands, available_isl, D, T;
                access_map = access_map,
                routing_graph = routing_graph,
            )
        else
            # 从真 AON 结果提取最后一步的 ISL 负载；link_id 对应完整候选边顺序。
            _extract_last_isl_loads(traffic_evaluation, length(traffic_isl_candidates))
        end
    elseif n_isl > 0
        [config.constraints.isl_max_capacity_mbps * 0.5 for _ in 1:n_isl]
    else
        Float64[]
    end
    utilization = if !isempty(link_loads)
        compute_link_utilization(
            link_loads,
            [config.constraints.isl_max_capacity_mbps for _ in eachindex(link_loads)],
        )
    else
        compute_link_utilization(Float64[], Float64[])
    end

    if traffic_evaluation !== nothing
        traffic_routing_results = _routing_outputs_from_traffic(traffic_evaluation, route_label)
        if !isempty(traffic_routing_results)
            routing_results = traffic_routing_results
            latency = _latency_from_traffic(traffic_evaluation)
            network = _network_from_traffic(traffic_evaluation)
        end
    end

    routing_metrics = compute_routing_metrics(routing_results)
    max_isl = T * 4 ÷ 2
    fitness = (1 - config.alpha) * routing_metrics.avg_hop_count +
              config.alpha * (max_isl > 0 ? n_isl * 10 / max_isl : 0.0)

    return ExperimentResult(
        config, coverage, latency, network, utilization,
        routing_metrics, fitness, time() - t_start,
        traffic_evaluation,
    )
end

function _network_from_traffic(traffic_evaluation)
    total = 0
    routed = 0
    delays_ms = Float64[]
    for assignments in traffic_evaluation.assignments_by_time
        for assignment in assignments
            total += 1
            route_path = assignment.route
            route_path.reachable || continue
            routed += 1
            route_path.total_delay_s === nothing || push!(delays_ms, 1000.0 * route_path.total_delay_s)
        end
    end

    total == 0 && return NetworkMetrics(0.0, 0.0, false, 0.0)
    connectivity_ratio = routed / total
    if isempty(delays_ms)
        return NetworkMetrics(0.0, 0.0, false, connectivity_ratio)
    end
    return NetworkMetrics(
        maximum(delays_ms),
        sum(delays_ms) / length(delays_ms),
        routed == total,
        connectivity_ratio,
    )
end

function _latency_from_traffic(traffic_evaluation)
    samples_ms = Float64[]
    for assignments in traffic_evaluation.assignments_by_time
        for assignment in assignments
            route_path = assignment.route
            route_path.reachable || continue
            route_path.total_delay_s === nothing && continue
            push!(samples_ms, 1000.0 * route_path.total_delay_s)
        end
    end

    if isempty(samples_ms)
        return LatencyResult(0.0, 0.0, 0.0, 0)
    end

    sorted_vals = sort(samples_ms)
    return LatencyResult(
        sum(samples_ms) / length(samples_ms),
        maximum(samples_ms),
        minimum(samples_ms),
        length(samples_ms),
        _quantile_sorted(sorted_vals, 0.50),
        _quantile_sorted(sorted_vals, 0.95),
        _quantile_sorted(sorted_vals, 0.99),
        sorted_vals,
    )
end

function _quantile_sorted(sorted_vals::Vector{Float64}, q::Float64)
    isempty(sorted_vals) && return 0.0
    q <= 0 && return first(sorted_vals)
    q >= 1 && return last(sorted_vals)
    pos = 1 + (length(sorted_vals) - 1) * q
    lo = floor(Int, pos)
    hi = ceil(Int, pos)
    lo == hi && return sorted_vals[lo]
    frac = pos - lo
    return sorted_vals[lo] * (1 - frac) + sorted_vals[hi] * frac
end

function _routing_outputs_from_traffic(traffic_evaluation, route_label::String)
    outputs = RoutingOutput[]
    for assignments in traffic_evaluation.assignments_by_time
        for assignment in assignments
            route_path = assignment.route
            if route_path.reachable
                push!(outputs, RoutingOutput(
                    route_path.satellite_path,
                    route_path.total_delay_s === nothing ? 0.0 : 1000.0 * route_path.total_delay_s,
                    string(route_label, ":", route_path.reason),
                ))
            else
                push!(outputs, RoutingOutput(Int[], Inf, string(route_label, ":", route_path.reason)))
            end
        end
    end
    return outputs
end

# ────────────────────────────────────────────────────────────
# 流量分配（AoN 最简形式）：demand → ISL 负载
# ────────────────────────────────────────────────────────────

"""
    _assign_demands_to_isls(demands, available_isl, D, N) -> Vector{Float64}

把每条流量需求按最短路径分配到 ISL，返回每条 ISL 的累加负载（Mbps）。
AoN（All-or-Nothing）分配：每条 demand 全量走其最短路径。

# 参数
- `demands`: TrafficDemand 列表（source/destination 当作卫星索引）
- `available_isl`: ISL 边列表 [(i,j),...]
- `D`: 全对最短路径距离矩阵（卫星索引）
- `N`: 卫星总数
"""
function _assign_demands_to_isls(
    demands, available_isl, D, N;
    access_map=nothing, routing_graph=nothing,
)
    loads = zeros(Float64, length(available_isl))
    edge_index = Dict{Tuple{Int,Int},Int}()
    for (k, (i, j)) in enumerate(available_isl)
        edge_index[(i, j)] = k
        edge_index[(j, i)] = k
    end
    for demand in demands
        src_g = demand.source_ground_id
        dst_g = demand.destination_ground_id
        if access_map !== nothing
            haskey(access_map, src_g) || continue
            haskey(access_map, dst_g) || continue
            src = access_map[src_g].sat_id
            dst = access_map[dst_g].sat_id
        else
            (src_g < 1 || src_g > N || dst_g < 1 || dst_g > N) && continue
            src, dst = src_g, dst_g
        end
        src == dst && continue
        path = if routing_graph !== nothing
            route(DijkstraRouting(), RoutingInput(routing_graph, src, dst)).path
        else
            !isfinite(D[src, dst]) && continue
            _dijkstra_sat_path(src, dst, D, N, edge_index)
        end
        for k in 2:length(path)
            e = (path[k-1], path[k])
            haskey(edge_index, e) && (loads[edge_index[e]] += demand.rate_mbps)
        end
    end
    return loads
end

# ────────────────────────────────────────────────────────────
# 完整 AON 流量评估（多时间步，通过桥接调 evaluate_traffic）
# ────────────────────────────────────────────────────────────

function _simulation_time_grid_from_tspan(tspan, n_time::Int)
    n_time >= 1 || return nothing
    length(tspan) == n_time || return nothing
    isempty(tspan) && return nothing

    time_tol = 1e-6
    first_offset = Float64(first(tspan))
    isfinite(first_offset) || return nothing
    isapprox(first_offset, 0.0; atol = time_tol, rtol = 0.0) || return nothing

    offsets = Int[]
    for value in tspan
        offset = Float64(value)
        isfinite(offset) || return nothing
        rounded = round(Int, offset)
        isapprox(offset, rounded; atol = time_tol, rtol = 0.0) || return nothing
        push!(offsets, rounded)
    end

    first(offsets) == 0 || return nothing
    any(offset -> offset < 0, offsets) && return nothing
    n_time == 1 && return SimulationTimeGrid(default_starlink_simulation_epoch(), 0, 1)

    deltas = diff(offsets)
    any(delta -> delta <= 0, deltas) && return nothing
    step = first(deltas)
    step > 0 || return nothing

    grid = SimulationTimeGrid(default_starlink_simulation_epoch(), last(offsets), step)
    time_count(grid) == n_time || return nothing
    timeslot_offsets(grid) == offsets || return nothing
    return grid
end

"""
    _evaluate_traffic_full(config, positions, isl_pairs) -> Union{Nothing,TrafficEvaluation}

构造多时间步的 ISL/GSL 评估数据，调 evaluate_traffic_from_bare_arrays 跑完整 AON。
需要 ground_stations 作为地面端点；无 ground_stations、无时间步或无 ISL 则返回 nothing（降级）。
"""
function _evaluate_traffic_full(config, positions, isl_pairs)
    n_time = size(positions, 2)
    n_time >= 1 || return nothing
    isempty(config.ground_stations) && return nothing
    isempty(isl_pairs) && return nothing

    # 地面站经纬高（统一经 _ground_station_tuple）；id 保留配置原值
    gs_tuples = [_ground_station_tuple(gs) for gs in config.ground_stations]
    ground_ids = _ground_station_ids(config.ground_stations)

    # 构造和 positions 时间维严格一致的时间网格。
    grid = _simulation_time_grid_from_tspan(config.tspan, n_time)
    grid === nothing && return nothing

    # 每时间步评估 ISL + GSL
    isl_results_by_time = [
        evaluate_isl_batch(positions[:,t,:], isl_pairs; constraints=config.constraints)
        for t in 1:n_time
    ]
    gsl_avail = Matrix{Bool}[]
    gsl_dist = Matrix{Float64}[]
    gsl_elev = Matrix{Float64}[]
    gsl_delay = Matrix{Float64}[]
    for t in 1:n_time
        a, d, e, delay = evaluate_gsl_batch(positions[:,t,:], gs_tuples; constraints=config.constraints)
        push!(gsl_avail, a); push!(gsl_dist, d); push!(gsl_elev, e); push!(gsl_delay, delay)
    end

    # 调完整 AON
    return evaluate_traffic_from_bare_arrays(
        positions, isl_pairs, isl_results_by_time,
        gsl_avail, gsl_dist, gsl_elev,
        ground_ids, grid, config.traffic_demands;
        isl_capacity_mbps = config.constraints.isl_max_capacity_mbps,
        gsl_delay_ms_by_time = gsl_delay,
        routing_algorithm = config.routing_algorithm,
    )
end

"""
    _extract_last_isl_loads(traffic_evaluation, n_isl) -> Vector{Float64}

从 TrafficEvaluation 提取最后一步的每条 ISL 负载（Mbps）。
用于和旧 link_loads 接口兼容（compute_link_utilization 需要 Vector{Float64}）。
"""
function _extract_last_isl_loads(tev, n_isl::Int)
    isempty(tev.link_loads_by_time) && return zeros(Float64, n_isl)
    last_loads = tev.link_loads_by_time[end]
    # 只取 ISL 类型的负载（GSL 的 link_type 不同）
    loads = zeros(Float64, n_isl)
    for sample in last_loads
        if hasfield(typeof(sample), :link_type) && sample.link_type == :isl
            hasfield(typeof(sample), :link_id) && 1 <= sample.link_id <= n_isl &&
                (loads[sample.link_id] = sample.load_mbps)
        end
    end
    return loads
end

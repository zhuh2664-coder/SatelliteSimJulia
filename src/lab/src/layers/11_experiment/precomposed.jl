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
using SatelliteSimTraffic: TrafficDemand, evaluate_traffic_from_bare_arrays
import Random
# 从 Foundation 借时间网格（Core re-export 了 Foundation，但 SimulationTimeGrid 需要显式引用）
import SatelliteSimFoundation: SimulationTimeGrid, default_starlink_simulation_epoch

export propagate_constellation_positions, assess_coverage, assess_routing,
       assess_routing_temporal, full_constellation_assessment

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
    positions = propagate_to_ecef(elems, config.tspan; propagator = config.propagator)
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
    assess_routing(positions, T, P, strategy, constraints; ground_pairs) -> (D, available_isl, isl_results)

预编排：位置 → 拓扑生成 → ISL 批评估 → 邻接表 → 全对最短路径。

输入：
- `positions::Array{Float64,3}`：N×T×3 ECEF 位置
- `T::Int, P::Int`：卫星总数和轨道面数
- `strategy`：拓扑策略（如 GridPlusStrategy()）
- `constraints`：物理约束

返回距离矩阵 D、可用 ISL 列表、ISL 评估结果。
"""
function assess_routing(
    positions::Array{Float64,3}, T::Int, P::Int,
    strategy, constraints; ground_pairs = Tuple{Int,Int}[],
)
    last_pos = positions_at_last(positions)
    topo_output = generate_topology(strategy, T, P)
    all_links = vcat(topo_output.static_links, topo_output.dynamic_candidates)

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
        positions, T, P, config.topology_strategy, config.constraints;
        ground_pairs = config.ground_pairs,
    )

    latency = compute_latency(D)
    network = compute_network_metrics(D)

    # 路由结果（用于 routing_metrics）
    # 注意：当前评估用全对最短路径距离矩阵 D（Floyd-Warshall）。
    # routing_algorithm 字段记录用户意图，但 ECMP/MinLoad 的逐流 route() 接口
    # 与矩阵模型不兼容，故此处标签反映意图，实际路径仍走最短路径。
    # 完整的逐流路由评估（ECMP 分散/MLB 负载感知）待 route() 接口统一后接入。
    route_label = string(typeof(config.routing_algorithm).name.name)
    # 路由端点：优先 ground_pairs；否则若 ground_stations 非空，从它生成配对；
    # 最后降级为默认对跖点配对
    if !isempty(config.ground_pairs)
        pairs = config.ground_pairs
    elseif !isempty(config.ground_stations)
        # ground_stations 作为端点：取前 min(10, n) 个两两配对
        gs_ids = 1:min(length(config.ground_stations), T)
        pairs = [(a, b) for (k, a) in enumerate(gs_ids) for b in gs_ids[k+1:end]]
        pairs = isempty(pairs) ? [(1, mod1(1 + div(T, 2), T))] : pairs
    else
        pairs = [(i, mod1(i + div(T, 2), T)) for i in 1:min(100, T)]
    end
    routing_results = RoutingOutput[]
    for (source, destination) in pairs
        if isfinite(D[source, destination])
            push!(routing_results, RoutingOutput([source, destination], D[source, destination], route_label))
        else
            push!(routing_results, RoutingOutput(Int[], Inf, route_label * "-unreachable"))
        end
    end

    n_isl = length(available_isl)
    # 流量评估：尝试完整 AON（多时间步），失败则降级到占位（向后兼容）
    traffic_evaluation = nothing
    link_loads = if n_isl > 0 && !isempty(config.traffic_demands)
        traffic_evaluation = try
            _evaluate_traffic_full(config, positions, available_isl)
        catch
            nothing  # 降级
        end
        if traffic_evaluation === nothing
            # 降级：旧占位路径
            _assign_demands_to_isls(config.traffic_demands, available_isl, D, T)
        else
            # 从真 AON 结果提取最后一步的 ISL 负载
            _extract_last_isl_loads(traffic_evaluation, n_isl)
        end
    elseif n_isl > 0
        [config.constraints.isl_max_capacity_mbps * 0.5 for _ in 1:n_isl]
    else
        Float64[]
    end
    utilization = if n_isl > 0
        compute_link_utilization(
            link_loads,
            [config.constraints.isl_max_capacity_mbps for _ in 1:n_isl],
        )
    else
        compute_link_utilization(Float64[], Float64[])
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
function _assign_demands_to_isls(demands, available_isl, D, N)
    loads = zeros(Float64, length(available_isl))
    # 建 ISL 边 → 索引的快速查找表
    edge_index = Dict{Tuple{Int,Int},Int}()
    for (k, (i, j)) in enumerate(available_isl)
        edge_index[(i, j)] = k
        edge_index[(j, i)] = k
    end
    # 简化路径重建：从 D 重建最短路径（用相邻卫星 hop 序列）
    # 这里用 Dijkstra 重建路径（从 D 的前驱信息不可得，用贪婪 hop 重建）
    for demand in demands
        src = clamp(demand.source_ground_id, 1, N)
        dst = clamp(demand.destination_ground_id, 1, N)
        src == dst && continue
        !isfinite(D[src, dst]) && continue   # 不可达，跳过
        # 贪婪重建最短路径：每步选使剩余距离最小的邻居
        path = _reconstruct_path(src, dst, D, N, edge_index)
        for k in 2:length(path)
            e = (path[k-1], path[k])
            haskey(edge_index, e) && (loads[edge_index[e]] += demand.rate_mbps)
        end
    end
    return loads
end

"""贪婪重建最短路径：每步选使 (当前到邻居) + (邻居到终点) 最小的下一跳。"""
function _reconstruct_path(src::Int, dst::Int, D, N::Int, edge_index)
    path = [src]
    current = src
    visited = Set([src])
    for _ in 1:N
        current == dst && break
        best_next = 0
        best_cost = Inf
        for nb in 1:N
            nb == current && continue
            nb in visited && continue
            haskey(edge_index, (current, nb)) || continue  # 必须有 ISL 直连
            !isfinite(D[nb, dst]) && continue
            cost = D[current, nb] + D[nb, dst]
            cost < best_cost && (best_cost = cost; best_next = nb)
        end
        best_next == 0 && break   # 无路可走
        push!(path, best_next)
        push!(visited, best_next)
        current = best_next
    end
    return path
end

# ────────────────────────────────────────────────────────────
# 完整 AON 流量评估（多时间步，通过桥接调 evaluate_traffic）
# ────────────────────────────────────────────────────────────

"""
    _evaluate_traffic_full(config, positions, isl_pairs) -> Union{Nothing,TrafficEvaluation}

构造多时间步的 ISL/GSL 评估数据，调 evaluate_traffic_from_bare_arrays 跑完整 AON。
需要 ground_stations 作为地面端点；无 ground_stations 或 tspan 不足 2 步则返回 nothing（降级）。
"""
function _evaluate_traffic_full(config, positions, isl_pairs)
    n_time = size(positions, 2)
    n_time >= 1 || return nothing
    isempty(config.ground_stations) && return nothing
    isempty(isl_pairs) && return nothing

    # 地面站经纬度
    gs_tuples = [
        (gs.position.latitude_deg, gs.position.longitude_deg, gs.position.altitude_km)
        for gs in config.ground_stations
    ]
    ground_ids = collect(1:length(gs_tuples))

    # 构造时间网格
    tspan = config.tspan
    duration = isempty(tspan) ? 0 : Int(round(maximum(tspan) - minimum(tspan)))
    step = length(tspan) >= 2 ? Int(round(tspan[2] - tspan[1])) : max(duration, 1)
    step = max(step, 1)
    grid = SimulationTimeGrid(default_starlink_simulation_epoch(), duration, step)

    # 每时间步评估 ISL + GSL
    isl_results_by_time = [
        evaluate_isl_batch(positions[:,t,:], isl_pairs; constraints=config.constraints)
        for t in 1:n_time
    ]
    gsl_avail, gsl_dist, gsl_elev = Matrix{Bool}[], Matrix{Float64}[], Matrix{Float64}[]
    for t in 1:n_time
        a, d, e, _ = evaluate_gsl_batch(positions[:,t,:], gs_tuples; constraints=config.constraints)
        push!(gsl_avail, a); push!(gsl_dist, d); push!(gsl_elev, e)
    end

    # 调完整 AON
    return evaluate_traffic_from_bare_arrays(
        positions, isl_pairs, isl_results_by_time,
        gsl_avail, gsl_dist, gsl_elev,
        ground_ids, grid, config.traffic_demands;
        isl_capacity_mbps = config.constraints.isl_max_capacity_mbps,
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

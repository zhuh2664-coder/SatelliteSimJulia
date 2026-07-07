# ===== 流量层核心模块（从 legacy/05_traffic/aon.jl 迁移）=====
# All-or-Nothing 流量分配：将 TrafficDemand 按 RoutePath 分配到 ISL/GSL 链路
# 依赖：Net(RoutePath/AccessDecisionTable/route_path_at) + Link(ISLPhysicalLinkSeries/link_samples_at) + Foundation(SimulationTimeGrid)

using SatelliteSimFoundation
using SatelliteSimLink
using SatelliteSimCore
using SatelliteSimNet

export TrafficDemand, TrafficAssignment, LinkLoadSample, TrafficEvaluation,
       evaluate_traffic

"""
    TrafficDemand

描述一条地面端点之间的业务流需求。

# 说明
# TrafficDemand 代表一个 OD（Origin-Destination）流量需求。
# 时间区间 [start_elapsed_s, end_elapsed_s) 采用左闭右开区间，
# 保证任意时刻至多属于一个需求的时间窗口，避免边界重复计算。
# rate_mbps 是该需求的恒定速率，表示在活跃期间持续以该速率产生流量。

# 字段
- `id::Int`：业务流唯一正整数标识。
- `source_ground_id::Int`：源地面端点编号。
- `destination_ground_id::Int`：目的地面端点编号，必须与源不同。
- `start_elapsed_s::Int`：业务流开始时刻（相对仿真起点的秒数，含）。
- `end_elapsed_s::Int`：业务流结束时刻（相对仿真起点的秒数，不含）。
- `rate_mbps::Float64`：业务流速率（Mbps），必须非负。
"""
struct TrafficDemand
    id::Int
    source_ground_id::Int
    destination_ground_id::Int
    start_elapsed_s::Int
    end_elapsed_s::Int
    rate_mbps::Float64

    function TrafficDemand(;
        id::Int,
        source_ground_id::Int,
        destination_ground_id::Int,
        start_elapsed_s::Int,
        end_elapsed_s::Int,
        rate_mbps::Real,
    )
        id > 0 || throw(ArgumentError("traffic demand id must be positive"))
        source_ground_id > 0 || throw(ArgumentError("source_ground_id must be positive"))
        destination_ground_id > 0 || throw(ArgumentError("destination_ground_id must be positive"))
        source_ground_id != destination_ground_id ||
            throw(ArgumentError("source and destination ground ids must differ"))
        start_elapsed_s >= 0 || throw(ArgumentError("start_elapsed_s must be non-negative"))
        end_elapsed_s > start_elapsed_s ||
            throw(ArgumentError("end_elapsed_s must be greater than start_elapsed_s"))
        rate_mbps >= 0 || throw(ArgumentError("rate_mbps must be non-negative"))
        return new(
            id,
            source_ground_id,
            destination_ground_id,
            start_elapsed_s,
            end_elapsed_s,
            Float64(rate_mbps),
        )
    end
end

"""
    TrafficAssignment

描述一个业务流在某个时隙上的路由分配结果。

# 流量映射到链路负载的过程
#
# 对于一个可达的需求 d，其流量 f_d 按照路由路径 P_d 映射到链路负载：
#   1. 源 GSL：f_d 累加到源地面端点 → 源接入卫星 的 GSL 链路
#   2. 目的 GSL：f_d 累加到目的接入卫星 → 目的地面端点 的 GSL 链路
#   3. ISL 路径：f_d 沿 satellite_path 逐跳累加到每个 ISL 链路
#      对路径 P = [s_1, s_2, ..., s_n]，负载分别加到：
#        ISL(s_1→s_2), ISL(s_2→s_3), ..., ISL(s_{n-1}→s_n)
#
# 流量守恒约束：offered = carried + dropped
# 在 AON 模式下，可达时 carried = offered，dropped = 0；
# 不可达时 carried = 0，dropped = offered。

# 字段
- `demand_id::Int`：对应的 TrafficDemand 编号。
- `time_index::Int`：所在时隙索引（从 1 开始）。
- `elapsed_s::Int`：该时隙对应的仿真已运行秒数。
- `route::RoutePath`：由网络层路由计算得到的路径；不可达时 reachable 为 false。
- `offered_mbps::Float64`：该时隙提供的业务速率（通常等于 demand.rate_mbps）。
- `carried_mbps::Float64`：实际被网络成功承载的速率。
- `dropped_mbps::Float64`：因路径不可达等原因被丢弃的速率，满足
  `offered_mbps ≈ carried_mbps + dropped_mbps`。
"""
struct TrafficAssignment
    demand_id::Int
    time_index::Int
    elapsed_s::Int
    route::RoutePath
    offered_mbps::Float64
    carried_mbps::Float64
    dropped_mbps::Float64

    function TrafficAssignment(;
        demand_id::Int,
        time_index::Int,
        elapsed_s::Int,
        route::RoutePath,
        offered_mbps::Real,
        carried_mbps::Real,
        dropped_mbps::Real,
    )
        demand_id > 0 || throw(ArgumentError("demand_id must be positive"))
        time_index > 0 || throw(ArgumentError("time_index must be positive"))
        elapsed_s >= 0 || throw(ArgumentError("elapsed_s must be non-negative"))
        route.time_index == time_index ||
            throw(ArgumentError("route time_index must match assignment time_index"))
        offered_mbps >= 0 || throw(ArgumentError("offered_mbps must be non-negative"))
        carried_mbps >= 0 || throw(ArgumentError("carried_mbps must be non-negative"))
        dropped_mbps >= 0 || throw(ArgumentError("dropped_mbps must be non-negative"))
        abs(Float64(offered_mbps) - Float64(carried_mbps) - Float64(dropped_mbps)) <= 1e-9 ||
            throw(ArgumentError("offered_mbps must equal carried_mbps + dropped_mbps"))
        return new(
            demand_id,
            time_index,
            elapsed_s,
            route,
            Float64(offered_mbps),
            Float64(carried_mbps),
            Float64(dropped_mbps),
        )
    end
end

"""
    LinkLoadSample

描述某条链路在一个时隙上的负载样本。

# 链路负载累加算法
#
# 同一链路在同一时隙可能被多个业务流复用。负载累加过程：
#   loads[key] = Σ (carried_mbps of all demands routed through this link)
#
# 使用字典 Dict{Tuple, Float64} 存储，键为 (link_type, link_id) 或 (:gsl, ground_id, sat_id)。
# 这种"先累加、后打包"的方式避免了中间数据结构的重复分配。

# 利用率计算：
#   utilization = load / capacity
#   特殊处理：
#     - 容量为 Inf（如 GSL 不可用时不计容量约束）→ utilization = 0.0
#     - 容量为 0 且负载为正 → utilization = Inf（表示完全拥塞）
#     - 容量为 0 且负载为 0 → utilization = 0.0
#   拥塞判定：congested = (load > capacity)，与 utilization 解耦以处理 Inf 情况。

# 字段
- `link_type::Symbol`：链路类型，仅允许 `:isl` 或 `:gsl`。
- `link_id::Union{Nothing,Int}`：ISL 在拓扑中的链路编号；GSL 无固定链路编号，故为 `nothing`。
- `endpoint_a_id::Int`：链路一端编号（ISL 为卫星编号，GSL 为地面端点编号）。
- `endpoint_b_id::Int`：链路另一端编号（ISL 为卫星编号，GSL 为卫星编号）。
- `time_index::Int`：时隙索引。
- `elapsed_s::Int`：该时隙对应的仿真已运行秒数。
- `load_mbps::Float64`：该链路上的总负载速率（Mbps）。
- `capacity_mbps::Float64`：链路容量（Mbps）；GSL 不可用时可能为 `Inf`，表示不计容量约束。
- `utilization::Float64`：负载占容量的比例；容量为 0 且负载为正时取 `Inf`。
- `congested::Bool`：当 `load_mbps > capacity_mbps` 时为 true，表示发生拥塞。
"""
struct LinkLoadSample
    link_type::Symbol
    link_id::Union{Nothing,Int}
    endpoint_a_id::Int
    endpoint_b_id::Int
    time_index::Int
    elapsed_s::Int
    load_mbps::Float64
    capacity_mbps::Float64
    utilization::Float64
    congested::Bool

    function LinkLoadSample(;
        link_type::Symbol,
        link_id::Union{Nothing,Int} = nothing,
        endpoint_a_id::Int,
        endpoint_b_id::Int,
        time_index::Int,
        elapsed_s::Int,
        load_mbps::Real,
        capacity_mbps::Real,
    )
        link_type in (:isl, :gsl) || throw(ArgumentError("link_type must be :isl or :gsl"))
        link_id === nothing || link_id > 0 ||
            throw(ArgumentError("link_id must be positive when provided"))
        endpoint_a_id > 0 || throw(ArgumentError("endpoint_a_id must be positive"))
        endpoint_b_id > 0 || throw(ArgumentError("endpoint_b_id must be positive"))
        if link_type == :isl
            endpoint_a_id != endpoint_b_id || throw(ArgumentError("ISL endpoints must differ"))
        end
        time_index > 0 || throw(ArgumentError("time_index must be positive"))
        elapsed_s >= 0 || throw(ArgumentError("elapsed_s must be non-negative"))
        load_mbps >= 0 || throw(ArgumentError("load_mbps must be non-negative"))
        capacity_mbps >= 0 || throw(ArgumentError("capacity_mbps must be non-negative"))

        capacity = Float64(capacity_mbps)
        load = Float64(load_mbps)
        utilization = isinf(capacity) ? 0.0 :
                      capacity == 0 ? (load == 0 ? 0.0 : Inf) :
                      load / capacity
        congested = load > capacity
        return new(
            link_type,
            link_id,
            endpoint_a_id,
            endpoint_b_id,
            time_index,
            elapsed_s,
            load,
            capacity,
            utilization,
            congested,
        )
    end
end

"""
    TrafficEvaluation

封装一次流量评估的全部结果，包括原始需求、每个时隙的分配结果和链路负载。

# 字段
- `time_grid::SimulationTimeGrid`：用于对齐所有样本的时间网格。
- `demands::Vector{TrafficDemand}`：参与评估的所有业务需求。
- `assignments_by_time::Vector{Vector{TrafficAssignment}}`：每个时隙的分配结果列表。
- `link_loads_by_time::Vector{Vector{LinkLoadSample}}`：每个时隙的链路负载样本列表。
"""
struct TrafficEvaluation
    time_grid::SimulationTimeGrid
    demands::Vector{TrafficDemand}
    assignments_by_time::Vector{Vector{TrafficAssignment}}
    link_loads_by_time::Vector{Vector{LinkLoadSample}}

    function TrafficEvaluation(
        time_grid::SimulationTimeGrid,
        demands::Vector{TrafficDemand},
        assignments_by_time::Vector{Vector{TrafficAssignment}},
        link_loads_by_time::Vector{Vector{LinkLoadSample}},
    )
        length(unique(demand.id for demand in demands)) == length(demands) ||
            throw(ArgumentError("traffic demand ids must be unique"))
        length(assignments_by_time) == time_count(time_grid) ||
            throw(ArgumentError("assignments_by_time must match the time grid length"))
        length(link_loads_by_time) == time_count(time_grid) ||
            throw(ArgumentError("link_loads_by_time must match the time grid length"))
        for (time_index, assignments) in pairs(assignments_by_time)
            for assignment in assignments
                assignment.time_index == time_index ||
                    throw(ArgumentError("assignment time_index must match time slice order"))
            end
        end
        for (time_index, loads) in pairs(link_loads_by_time)
            for load in loads
                load.time_index == time_index ||
                    throw(ArgumentError("link load time_index must match time slice order"))
            end
        end
        return new(time_grid, demands, assignments_by_time, link_loads_by_time)
    end
end

"""
    traffic_assignments_at(evaluation::TrafficEvaluation, time_index::Int)::Vector{TrafficAssignment}

获取指定时隙的所有流量分配结果。
"""
traffic_assignments_at(evaluation::TrafficEvaluation, time_index::Int)::Vector{TrafficAssignment} =
    evaluation.assignments_by_time[time_index]

"""
    traffic_link_loads_at(evaluation::TrafficEvaluation, time_index::Int)::Vector{LinkLoadSample}

获取指定时隙的所有链路负载样本。
"""
traffic_link_loads_at(evaluation::TrafficEvaluation, time_index::Int)::Vector{LinkLoadSample} =
    evaluation.link_loads_by_time[time_index]

"""
    is_active(demand::TrafficDemand, elapsed_s::Int)::Bool

判断给定业务需求在 `elapsed_s` 时刻是否处于活跃区间。
区间为左闭右开：`[start_elapsed_s, end_elapsed_s)`。
"""
is_active(demand::TrafficDemand, elapsed_s::Int)::Bool =
    demand.start_elapsed_s <= elapsed_s < demand.end_elapsed_s

"""
    route_request(demand::TrafficDemand)::RouteRequest

由业务需求构造对应的路由请求（源/目的地面端点）。
"""
route_request(demand::TrafficDemand)::RouteRequest =
    RouteRequest(demand.source_ground_id, demand.destination_ground_id)

"""
    add_link_load!(loads, metadata, key, load_mbps; link_type, link_id, endpoint_a_id, endpoint_b_id, capacity_mbps)

将 `load_mbps` 累加到 `loads[key]`，并在 `metadata[key]` 中记录链路的静态元数据。
同一链路在同一时隙可能被多个业务流复用，因此使用累加而非覆盖。
"""
function add_link_load!(
    loads::Dict{Tuple,Float64},
    metadata::Dict{Tuple,NamedTuple},
    key::Tuple,
    load_mbps::Real;
    link_type::Symbol,
    link_id::Union{Nothing,Int},
    endpoint_a_id::Int,
    endpoint_b_id::Int,
    capacity_mbps::Real,
)::Nothing
    loads[key] = get(loads, key, 0.0) + Float64(load_mbps)
    metadata[key] = (
        link_type = link_type,
        link_id = link_id,
        endpoint_a_id = endpoint_a_id,
        endpoint_b_id = endpoint_b_id,
        capacity_mbps = Float64(capacity_mbps),
    )
    return nothing
end

"""
    add_gsl_load!(loads, metadata, sample, ground_id, satellite_id, load_mbps)

为 GSL 链路累加负载。`sample` 为 `nothing` 时（例如路径不可达但仍被调用），
容量按 `Inf` 处理，表示该链路不引入容量约束。
"""
function add_gsl_load!(
    loads::Dict{Tuple,Float64},
    metadata::Dict{Tuple,NamedTuple},
    sample::Union{Nothing,GSLPhysicalLinkSample},
    ground_id::Int,
    satellite_id::Int,
    load_mbps::Real,
)::Nothing
    capacity = sample === nothing ? Inf : sample.capacity_mbps
    key = (:gsl, ground_id, satellite_id)
    add_link_load!(
        loads,
        metadata,
        key,
        load_mbps;
        link_type = :gsl,
        link_id = nothing,
        endpoint_a_id = ground_id,
        endpoint_b_id = satellite_id,
        capacity_mbps = capacity,
    )
    return nothing
end

"""
    add_isl_load!(loads, metadata, sample, load_mbps)

为 ISL 链路累加负载。链路的端点与容量直接从 `ISLPhysicalLinkSample` 读取。
"""
function add_isl_load!(
    loads::Dict{Tuple,Float64},
    metadata::Dict{Tuple,NamedTuple},
    sample::ISLPhysicalLinkSample,
    load_mbps::Real,
)::Nothing
    key = (:isl, sample.link_id)
    add_link_load!(
        loads,
        metadata,
        key,
        load_mbps;
        link_type = :isl,
        link_id = sample.link_id,
        endpoint_a_id = sample.endpoint_a_id,
        endpoint_b_id = sample.endpoint_b_id,
        capacity_mbps = sample.capacity_mbps,
    )
    return nothing
end

"""
    build_link_load_samples(time_index, elapsed_s, loads, metadata)::Vector{LinkLoadSample}

根据临时字典 `loads` 与 `metadata` 构造该时隙正式的 `LinkLoadSample` 列表。
按键的字符串表示排序，保证输出顺序稳定。
"""
function build_link_load_samples(
    time_index::Int,
    elapsed_s::Int,
    loads::Dict{Tuple,Float64},
    metadata::Dict{Tuple,NamedTuple},
)::Vector{LinkLoadSample}
    keys_sorted = sort(collect(keys(loads)); by = key -> string(key))
    return [
        begin
            item = metadata[key]
            LinkLoadSample(
                link_type = item.link_type,
                link_id = item.link_id,
                endpoint_a_id = item.endpoint_a_id,
                endpoint_b_id = item.endpoint_b_id,
                time_index = time_index,
                elapsed_s = elapsed_s,
                load_mbps = loads[key],
                capacity_mbps = item.capacity_mbps,
            )
        end
        for key in keys_sorted
    ]
end

"""
    evaluate_traffic(demands, isl_series, access_table)::TrafficEvaluation

对一组业务需求进行端到端流量评估。

# 参数
- `demands::Vector{TrafficDemand}`：待评估的业务需求集合。
- `isl_series::ISLPhysicalLinkSeries`：ISL 物理链路时序样本。
- `access_table::AccessDecisionTable`：每个地面端点在每个时隙的接入决策。

# 返回
- `TrafficEvaluation`：包含每个时隙的分配结果与链路负载。

# 算法流程
# 1. 检查时间网格一致性（ISL 链路与接入决策共享同一时间网格）
# 2. 遍历每个时隙 t_i：
#    a. 筛选活跃需求：is_active(demand, elapsed_s) → start <= elapsed < end
#    b. 对每个活跃需求计算路由：route_path_at(request, isl_series, access_table, i)
#    c. 执行 AON 分配：
#       - 可达：carried = rate, dropped = 0
#       - 不可达：carried = 0, dropped = rate
#    d. 将承载流量累加到路径上的 GSL 和 ISL 链路
#    e. 构造 LinkLoadSample 快照（包含负载、容量、利用率、拥塞标志）
# 3. 汇总为 TrafficEvaluation

# 依赖
- `is_active`、`route_request`、`route_path_at`（routing.jl）
- `access_decisions_at`（access.jl）
- `add_gsl_load!`、`add_isl_load!`、`build_link_load_samples`
"""
function evaluate_traffic(
    demands::Vector{TrafficDemand},
    isl_series::ISLPhysicalLinkSeries,
    access_table::AccessDecisionTable,
)::TrafficEvaluation
    # 时间网格必须一致，否则后续时隙索引无法对齐。
    isl_series.time_grid === access_table.time_grid ||
        throw(ArgumentError("ISL series and access table must share the same time_grid object"))
    length(unique(demand.id for demand in demands)) == length(demands) ||
        throw(ArgumentError("traffic demand ids must be unique"))

    assignments_by_time = Vector{Vector{TrafficAssignment}}()
    link_loads_by_time = Vector{Vector{LinkLoadSample}}()

    for time_index in 1:time_count(isl_series.time_grid)
        elapsed_s = timeslot_offsets(isl_series.time_grid)[time_index]
        assignments = TrafficAssignment[]
        loads = Dict{Tuple,Float64}()
        metadata = Dict{Tuple,NamedTuple}()
        isl_samples = link_samples_at(isl_series, time_index)

        for demand in demands
            is_active(demand, elapsed_s) || continue
            # 根据当前时隙的接入决策与 ISL 状态，计算该需求的路由。
            route = route_path_at(route_request(demand), isl_series, access_table, time_index)
            carried_mbps = route.reachable ? demand.rate_mbps : 0.0
            dropped_mbps = demand.rate_mbps - carried_mbps
            push!(
                assignments,
                TrafficAssignment(
                    demand_id = demand.id,
                    time_index = time_index,
                    elapsed_s = elapsed_s,
                    route = route,
                    offered_mbps = demand.rate_mbps,
                    carried_mbps = carried_mbps,
                    dropped_mbps = dropped_mbps,
                ),
            )

            route.reachable || continue
            # 路由可达时，分别在源/目的 GSL 以及途经 ISL 上累加负载。
            source_access = access_decisions_at(access_table, demand.source_ground_id, time_index)
            destination_access = access_decisions_at(access_table, demand.destination_ground_id, time_index)
            add_gsl_load!(
                loads,
                metadata,
                source_access.selected_sample,
                demand.source_ground_id,
                route.source_access_satellite_id,
                carried_mbps,
            )
            add_gsl_load!(
                loads,
                metadata,
                destination_access.selected_sample,
                demand.destination_ground_id,
                route.destination_access_satellite_id,
                carried_mbps,
            )
            for link_id in route.isl_link_ids
                add_isl_load!(loads, metadata, isl_samples[link_id], carried_mbps)
            end
        end

        push!(assignments_by_time, assignments)
        push!(link_loads_by_time, build_link_load_samples(time_index, elapsed_s, loads, metadata))
    end

    return TrafficEvaluation(isl_series.time_grid, demands, assignments_by_time, link_loads_by_time)
end

"""
    evaluate_traffic(demands, isl_series, access_table, algorithm)::TrafficEvaluation

对一组业务需求进行端到端流量评估，并显式使用网络层路由算法。

旧的三参数入口保持 AON shortest-delay 语义。本入口用于把 Net 路由算法
落到正式的 `TrafficAssignment` 和 `LinkLoadSample` 产物中：
`DijkstraRouting`/`ECMPRouting` 走 `route(...)` 分派，`MinLoadRouting`
按时间步内已分配负载逐流选择 min-load path。
"""
function evaluate_traffic(
    demands::Vector{TrafficDemand},
    isl_series::ISLPhysicalLinkSeries,
    access_table::AccessDecisionTable,
    algorithm::AbstractRoutingAlgorithm,
)::TrafficEvaluation
    isl_series.time_grid === access_table.time_grid ||
        throw(ArgumentError("ISL series and access table must share the same time_grid object"))
    length(unique(demand.id for demand in demands)) == length(demands) ||
        throw(ArgumentError("traffic demand ids must be unique"))
    _assert_aon_algorithm_supported(algorithm)

    assignments_by_time = Vector{Vector{TrafficAssignment}}()
    link_loads_by_time = Vector{Vector{LinkLoadSample}}()

    for time_index in 1:time_count(isl_series.time_grid)
        elapsed_s = timeslot_offsets(isl_series.time_grid)[time_index]
        assignments = TrafficAssignment[]
        loads = Dict{Tuple,Float64}()
        metadata = Dict{Tuple,NamedTuple}()
        isl_samples = link_samples_at(isl_series, time_index)
        snapshot = _routing_snapshot_from_isl_samples(isl_samples)
        current_loads = zeros(Float64, length(snapshot.edges))

        for demand in demands
            is_active(demand, elapsed_s) || continue
            route = _route_path_with_algorithm(
                route_request(demand),
                access_table,
                time_index,
                elapsed_s,
                snapshot,
                current_loads,
                algorithm,
            )
            carried_mbps = route.reachable ? demand.rate_mbps : 0.0
            dropped_mbps = demand.rate_mbps - carried_mbps
            push!(
                assignments,
                TrafficAssignment(
                    demand_id = demand.id,
                    time_index = time_index,
                    elapsed_s = elapsed_s,
                    route = route,
                    offered_mbps = demand.rate_mbps,
                    carried_mbps = carried_mbps,
                    dropped_mbps = dropped_mbps,
                ),
            )

            route.reachable || continue
            _add_route_loads!(
                loads,
                metadata,
                access_table,
                isl_samples,
                demand,
                route,
                time_index,
                carried_mbps,
            )
            _add_current_loads!(current_loads, snapshot, route.satellite_path, carried_mbps)
        end

        push!(assignments_by_time, assignments)
        push!(link_loads_by_time, build_link_load_samples(time_index, elapsed_s, loads, metadata))
    end

    return TrafficEvaluation(isl_series.time_grid, demands, assignments_by_time, link_loads_by_time)
end

function _assert_aon_algorithm_supported(algorithm::AbstractRoutingAlgorithm)::Nothing
    if algorithm isa CGRRouting
        throw(ArgumentError(
            "CGRRouting requires CGRContactPlan/time-expanded contact semantics and cannot be used " *
            "with Traffic AON RoutingInput. Add a CGR-specific traffic adapter before using it here.",
        ))
    elseif algorithm isa PINNRoutingAlgorithm
        throw(ArgumentError(
            "PINNRoutingAlgorithm currently predicts latency without returning a satellite path, " *
            "so it cannot generate Traffic AON LinkLoadSample. Add path semantics before using it here.",
        ))
    end
    return nothing
end

function _routing_snapshot_from_isl_samples(samples::Vector{<:ISLPhysicalLinkSample})
    available = [sample for sample in samples if sample.state isa LinkAvailable]
    edges = Tuple{Int,Int}[(sample.endpoint_a_id, sample.endpoint_b_id) for sample in available]
    weights = Float64[sample.propagation_delay_s for sample in available]
    capacities = Float64[sample.capacity_mbps for sample in available]
    link_ids = Int[sample.link_id for sample in available]
    n_nodes = isempty(samples) ? 0 : maximum(
        max(sample.endpoint_a_id, sample.endpoint_b_id) for sample in samples
    )
    graph = routing_graph_from_edges(n_nodes, edges, weights)

    edge_index = Dict{Tuple{Int,Int},Int}()
    for (idx, (src, dst)) in enumerate(edges)
        edge_index[(src, dst)] = idx
        edge_index[(dst, src)] = idx
    end

    return (
        graph = graph,
        edges = edges,
        weights = weights,
        capacities = capacities,
        link_ids = link_ids,
        edge_index = edge_index,
    )
end

function _route_path_with_algorithm(
    request::RouteRequest,
    access_table::AccessDecisionTable,
    time_index::Int,
    elapsed_s::Int,
    snapshot,
    current_loads::Vector{Float64},
    algorithm::AbstractRoutingAlgorithm,
)::RoutePath
    source_access = access_decisions_at(access_table, request.source_ground_id, time_index)
    destination_access = access_decisions_at(access_table, request.destination_ground_id, time_index)
    source_satellite_id = source_access.selected_satellite_id
    destination_satellite_id = destination_access.selected_satellite_id

    source_satellite_id === nothing && return route_unreachable(
        request, time_index, elapsed_s, source_satellite_id, destination_satellite_id, :source_no_access,
    )
    destination_satellite_id === nothing && return route_unreachable(
        request, time_index, elapsed_s, source_satellite_id, destination_satellite_id, :destination_no_access,
    )
    source_satellite_id == destination_satellite_id && return RoutePath(
        request = request,
        time_index = time_index,
        elapsed_s = elapsed_s,
        source_access_satellite_id = source_satellite_id,
        destination_access_satellite_id = destination_satellite_id,
        satellite_path = [source_satellite_id],
        isl_link_ids = Int[],
        isl_delay_s = 0.0,
        source_gsl_delay_s = source_access.selected_sample === nothing ?
            0.0 : source_access.selected_sample.propagation_delay_s,
        destination_gsl_delay_s = destination_access.selected_sample === nothing ?
            0.0 : destination_access.selected_sample.propagation_delay_s,
        total_delay_s = (source_access.selected_sample === nothing ?
            0.0 : source_access.selected_sample.propagation_delay_s) +
            (destination_access.selected_sample === nothing ?
                0.0 : destination_access.selected_sample.propagation_delay_s),
        reachable = true,
        reason = :same_access_satellite,
    )
    max(source_satellite_id, destination_satellite_id) <= snapshot.graph.n_nodes ||
        return route_unreachable(
            request, time_index, elapsed_s, source_satellite_id, destination_satellite_id, :isl_unreachable,
        )

    path = if algorithm isa MinLoadRouting
        min_load_path(
            snapshot.graph.n_nodes,
            snapshot.edges,
            snapshot.weights,
            source_satellite_id,
            destination_satellite_id,
            current_loads,
            snapshot.capacities;
            K=5,
        )
    else
        route(algorithm, RoutingInput(snapshot.graph, source_satellite_id, destination_satellite_id)).path
    end

    isempty(path) && return route_unreachable(
        request, time_index, elapsed_s, source_satellite_id, destination_satellite_id, :isl_unreachable,
    )

    link_path, isl_delay_s = _link_path_and_delay(snapshot, path)
    isfinite(isl_delay_s) || return route_unreachable(
        request, time_index, elapsed_s, source_satellite_id, destination_satellite_id, :isl_unreachable,
    )
    source_gsl_delay_s = source_access.selected_sample === nothing ?
        0.0 : source_access.selected_sample.propagation_delay_s
    destination_gsl_delay_s = destination_access.selected_sample === nothing ?
        0.0 : destination_access.selected_sample.propagation_delay_s
    total_delay_s = source_gsl_delay_s + isl_delay_s + destination_gsl_delay_s

    return RoutePath(
        request = request,
        time_index = time_index,
        elapsed_s = elapsed_s,
        source_access_satellite_id = source_satellite_id,
        destination_access_satellite_id = destination_satellite_id,
        satellite_path = path,
        isl_link_ids = link_path,
        isl_delay_s = isl_delay_s,
        source_gsl_delay_s = source_gsl_delay_s,
        destination_gsl_delay_s = destination_gsl_delay_s,
        total_delay_s = total_delay_s,
        reachable = true,
        reason = algorithm isa MinLoadRouting ? :min_load : :routing_algorithm,
    )
end

function _link_path_and_delay(snapshot, path::Vector{Int})
    link_path = Int[]
    total_delay_s = 0.0
    for hop in 1:length(path)-1
        edge_idx = get(snapshot.edge_index, (path[hop], path[hop + 1]), nothing)
        edge_idx === nothing && return Int[], Inf
        push!(link_path, snapshot.link_ids[edge_idx])
        total_delay_s += snapshot.weights[edge_idx]
    end
    return link_path, total_delay_s
end

function _add_current_loads!(
    current_loads::Vector{Float64},
    snapshot,
    path::Vector{Int},
    load_mbps::Real,
)::Nothing
    for hop in 1:length(path)-1
        edge_idx = get(snapshot.edge_index, (path[hop], path[hop + 1]), nothing)
        edge_idx === nothing && continue
        current_loads[edge_idx] += load_mbps
    end
    return nothing
end

function _add_route_loads!(
    loads::Dict{Tuple,Float64},
    metadata::Dict{Tuple,NamedTuple},
    access_table::AccessDecisionTable,
    isl_samples::Vector{<:ISLPhysicalLinkSample},
    demand::TrafficDemand,
    route::RoutePath,
    time_index::Int,
    carried_mbps::Real,
)::Nothing
    source_access = access_decisions_at(access_table, demand.source_ground_id, time_index)
    destination_access = access_decisions_at(access_table, demand.destination_ground_id, time_index)
    add_gsl_load!(
        loads,
        metadata,
        source_access.selected_sample,
        demand.source_ground_id,
        route.source_access_satellite_id,
        carried_mbps,
    )
    add_gsl_load!(
        loads,
        metadata,
        destination_access.selected_sample,
        demand.destination_ground_id,
        route.destination_access_satellite_id,
        carried_mbps,
    )
    for link_id in route.isl_link_ids
        add_isl_load!(loads, metadata, isl_samples[link_id], carried_mbps)
    end
    return nothing
end

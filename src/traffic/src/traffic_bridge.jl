# ===== 流量桥接：裸数组路径 → 嵌套类型 AON =====
#
# 桥接 lab 层(裸数组:positions 矩阵 + 距离矩阵 D)和 traffic 层(嵌套类型:
# ISLPhysicalLinkSeries + AccessDecisionTable)。
#
# 背景:lab 的 full_constellation_assessment 走裸数组路径(evaluate_isl_batch/
# evaluate_gsl_batch 返回 NamedTuple/矩阵),但完整的 evaluate_traffic 消费嵌套
# 类型。本文件提供桥接构造器,从裸数组评估结果构造嵌套类型,再调 evaluate_traffic。
#
# 新增于 2026-07-04(Phase 1 - A1)。

using SatelliteSimFoundation
using SatelliteSimLink
using SatelliteSimCore
using SatelliteSimNet

using SatelliteSimLink:
    LinkAvailable, LinkUnavailable, InterSatelliteLink,
    ISLPhysicalLinkSample, GSLPhysicalLinkSample,
    ISLPhysicalLinkSeries, ConstellationTopology, SatelliteLink, LinkEndpoint

export evaluate_traffic_from_bare_arrays

# ────────────────────────────────────────────────────────────
# 辅助：构造 ConstellationTopology（从 ISL 边列表）
# ────────────────────────────────────────────────────────────

"""
    _build_topology_from_edges(constellation_name, isl_pairs, n_satellites) -> ConstellationTopology

从 ISL 边列表构造一个 ConstellationTopology。
每条边 (i,j) 构造一个 SatelliteLink（id 从 1 递增）。
"""
function _build_topology_from_edges(
    constellation_name::String,
    isl_pairs::Vector{Tuple{Int,Int}},
)::ConstellationTopology
    links = SatelliteLink[]
    for (link_id, (i, j)) in enumerate(isl_pairs)
        push!(links, SatelliteLink(;
            id = link_id,
            endpoint_a = LinkEndpoint(i),
            endpoint_b = LinkEndpoint(j),
            link_type = InterSatelliteLink(),
            state = LinkAvailable(),
        ))
    end
    return ConstellationTopology(constellation_name, links)
end

function _isl_delay_s(result)::Float64
    if hasproperty(result, :latency_ms)
        return Float64(getproperty(result, :latency_ms)) / 1000.0
    end
    return Float64(getproperty(result, :distance_km)) / 299792.458
end

function _gsl_delay_s(
    gsl_delay_ms_by_time,
    gsl_dist_by_time::Vector{Matrix{Float64}},
    time_index::Int,
    sat_id::Int,
    ground_local::Int,
)::Float64
    if gsl_delay_ms_by_time !== nothing
        return Float64(gsl_delay_ms_by_time[time_index][sat_id, ground_local]) / 1000.0
    end
    return gsl_dist_by_time[time_index][sat_id, ground_local] / 299792.458
end

# ────────────────────────────────────────────────────────────
# 辅助：构造 ISLPhysicalLinkSeries（从裸数组位置 + 边列表 + 时间网格）
# ────────────────────────────────────────────────────────────

"""
    _build_isl_series(positions, isl_pairs, isl_results_by_time, time_grid, topology; capacity_mbps)

从裸数组位置矩阵序列 + evaluate_isl_batch 结果构造 ISLPhysicalLinkSeries。

# 参数
- `positions::Array{Float64,3}`: (N_sat × N_time × 3) ECEF 位置 km
- `isl_pairs::Vector{Tuple{Int,Int}}`: ISL 边列表（卫星索引，1-based）
- `isl_results_by_time::Vector{Vector{NamedTuple}}`: 每个时间步的 evaluate_isl_batch 结果
- `time_grid::SimulationTimeGrid`: 时间网格
- `topology::ConstellationTopology`: 拓扑（链路 id 顺序必须和 isl_pairs 一致）
- `capacity_mbps::Float64`: ISL 容量（可用时）
"""
function _build_isl_series(
    positions::Array{Float64,3},
    isl_pairs::Vector{Tuple{Int,Int}},
    isl_results_by_time::Vector,
    time_grid::SimulationTimeGrid,
    topology::ConstellationTopology;
    capacity_mbps::Float64 = 1000.0,
)::ISLPhysicalLinkSeries
    n_time = size(positions, 2)
    n_links = length(isl_pairs)
    samples_by_time = Vector{Vector{ISLPhysicalLinkSample{Float64}}}()

    for time_index in 1:n_time
        elapsed_s = Int(timeslot_offsets(time_grid)[time_index])
        samples = ISLPhysicalLinkSample{Float64}[]
        results = isl_results_by_time[time_index]
        for link_id in 1:n_links
            r = results[link_id]
            push!(samples, ISLPhysicalLinkSample{Float64}(;
                link_id = link_id,
                time_index = time_index,
                elapsed_s = elapsed_s,
                endpoint_a_id = isl_pairs[link_id][1],
                endpoint_b_id = isl_pairs[link_id][2],
                distance_km = r.distance_km,
                propagation_delay_s = _isl_delay_s(r),
                capacity_mbps = r.available ? capacity_mbps : 0.0,
                state = r.available ? LinkAvailable() : LinkUnavailable(),
                line_of_sight = r.line_of_sight,
            ))
        end
        push!(samples_by_time, samples)
    end

    return ISLPhysicalLinkSeries(topology, time_grid, samples_by_time)
end

# ────────────────────────────────────────────────────────────
# 辅助：构造 AccessDecisionTable（从 GSL 矩阵 + 地面站列表）
# ────────────────────────────────────────────────────────────

"""
    _build_access_table(gsl_avail_by_time, gsl_dist_by_time, gsl_elev_by_time, ground_ids, time_grid; capacity_mbps)

从 GSL 评估矩阵序列构造 AccessDecisionTable。
每时间步为每个地面站选可见卫星中仰角最高的（max-elevation 策略）。

# 参数
- `gsl_avail_by_time[t][i,j]`: 时间步 t、卫星 i、地面站 j 的可用性
- `gsl_dist_by_time[t][i,j]`: 距离 km
- `gsl_elev_by_time[t][i,j]`: 仰角度
- `ground_ids::Vector{Int}`: 地面端 id 列表（1-based）
- `time_grid`: 时间网格
- `capacity_mbps`: GSL 容量
"""
function _build_access_table(
    gsl_avail_by_time::Vector{Matrix{Bool}},
    gsl_dist_by_time::Vector{Matrix{Float64}},
    gsl_elev_by_time::Vector{Matrix{Float64}},
    ground_ids::Vector{Int},
    time_grid::SimulationTimeGrid;
    capacity_mbps::Float64 = 500.0,
    gsl_delay_ms_by_time = nothing,
    handover_policy = nothing,
)::AccessDecisionTable
    n_time = length(gsl_avail_by_time)
    decisions_by_ground = Dict{Int,Vector{AccessDecision}}()

    for ground_local in eachindex(ground_ids)
        ground_id = ground_ids[ground_local]
        decisions = AccessDecision[]
        prev_satellite_id = nothing
        for time_index in 1:n_time
            elapsed_s = Int(timeslot_offsets(time_grid)[time_index])
            visible_samples = GSLPhysicalLinkSample[]
            avail = gsl_avail_by_time[time_index][:, ground_local]  # 所有卫星对这地面站
            for sat_id in eachindex(avail)
                avail[sat_id] || continue
                push!(visible_samples, _gsl_sample_from_matrices(
                    gsl_dist_by_time,
                    gsl_elev_by_time,
                    gsl_delay_ms_by_time,
                    ground_id,
                    sat_id,
                    ground_local,
                    time_index,
                    elapsed_s,
                    capacity_mbps,
                ))
            end

            selected_sample = if handover_policy === nothing
                _select_max_elevation_sample(visible_samples)
            else
                select_satellite(handover_policy, visible_samples, prev_satellite_id)
            end
            prev_satellite_id = selected_sample === nothing ? nothing : selected_sample.satellite_id

            push!(decisions, AccessDecision(;
                ground_id = ground_id,
                time_index = time_index,
                selected_satellite_id = selected_sample === nothing ? nothing : selected_sample.satellite_id,
                selected_sample = selected_sample,
            ))
        end
        decisions_by_ground[ground_id] = decisions
    end

    return AccessDecisionTable(time_grid, decisions_by_ground)
end

function _gsl_sample_from_matrices(
    gsl_dist_by_time::Vector{Matrix{Float64}},
    gsl_elev_by_time::Vector{Matrix{Float64}},
    gsl_delay_ms_by_time,
    ground_id::Int,
    sat_id::Int,
    ground_local::Int,
    time_index::Int,
    elapsed_s::Int,
    capacity_mbps::Float64,
)
    return GSLPhysicalLinkSample{Float64}(;
        ground_id = ground_id,
        satellite_id = sat_id,
        time_index = time_index,
        elapsed_s = elapsed_s,
        distance_km = gsl_dist_by_time[time_index][sat_id, ground_local],
        propagation_delay_s = _gsl_delay_s(
            gsl_delay_ms_by_time,
            gsl_dist_by_time,
            time_index,
            sat_id,
            ground_local,
        ),
        elevation_deg = gsl_elev_by_time[time_index][sat_id, ground_local],
        capacity_mbps = capacity_mbps,
        state = LinkAvailable(),
    )
end

function _select_max_elevation_sample(samples::Vector{GSLPhysicalLinkSample})
    isempty(samples) && return nothing
    best = first(samples)
    for sample in Iterators.drop(samples, 1)
        sample.elevation_deg > best.elevation_deg && (best = sample)
    end
    return best
end

# ────────────────────────────────────────────────────────────
# 主接口：从裸数组评估结果跑完整 AON 流量分配
# ────────────────────────────────────────────────────────────

"""
    evaluate_traffic_from_bare_arrays(
        positions, isl_pairs, isl_results_by_time,
        gsl_avail_by_time, gsl_dist_by_time, gsl_elev_by_time,
        ground_ids, time_grid, demands;
        isl_capacity_mbps, gsl_capacity_mbps, constellation_name, routing_algorithm
    ) -> TrafficEvaluation

桥接入口：从裸数组路径的评估结果构造嵌套类型，调用完整 AON 流量分配。

这是 lab 层（裸数组）接入 traffic 层（嵌套类型 AON）的桥梁。
不再需要降级到 _assign_demands_to_isls 占位函数。

# 参数
- `positions::Array{Float64,3}`: (N_sat × N_time × 3) 卫星 ECEF 位置
- `isl_pairs`: ISL 边列表
- `isl_results_by_time`: 每时间步的 evaluate_isl_batch 结果（NamedTuple 向量）
- `gsl_avail/dist/elev_by_time`: 每时间步的 GSL 评估矩阵
- `ground_ids`: 地面端 id 列表
- `time_grid`: 时间网格
- `demands::Vector{TrafficDemand}`: 流量需求
- `isl_capacity_mbps`: ISL 容量（默认 1000）
- `gsl_capacity_mbps`: GSL 容量（默认 500）
- `gsl_delay_ms_by_time`: 可选 GSL delay 矩阵序列；提供时优先于 distance/c
- `routing_algorithm`: 可选 Net 路由算法；未提供时保持旧的 shortest-delay AON 语义
- `handover_policy`: 可选 GSL 接入/切换策略；未提供时保持旧 max-elevation 语义
- `capacity_aware`: 为 true 时走 `evaluate_traffic_capacity_aware`（准入控制，
  路径瓶颈残余容量不足则整条 drop，保证 load ≤ capacity）；此时忽略
  `routing_algorithm`（准入路径用基线 shortest-delay 路由）。

# 返回
- `TrafficEvaluation`: 完整流量评估（含 assignments、link_loads、拥塞、dropped）
"""
function evaluate_traffic_from_bare_arrays(
    positions::Array{Float64,3},
    isl_pairs::Vector{Tuple{Int,Int}},
    isl_results_by_time::Vector,
    gsl_avail_by_time::Vector{Matrix{Bool}},
    gsl_dist_by_time::Vector{Matrix{Float64}},
    gsl_elev_by_time::Vector{Matrix{Float64}},
    ground_ids::Vector{Int},
    time_grid::SimulationTimeGrid,
    demands::Vector{TrafficDemand};
    isl_capacity_mbps::Float64 = 1000.0,
    gsl_capacity_mbps::Float64 = 500.0,
    gsl_delay_ms_by_time = nothing,
    constellation_name::String = "bridge",
    routing_algorithm = nothing,
    handover_policy = nothing,
    capacity_aware::Bool = false,
    admission_order::Symbol = :offered_desc,
)::TrafficEvaluation
    time_count(time_grid) == size(positions, 2) ||
        throw(ArgumentError("time_grid length must match positions time dimension"))

    # 1. 构造拓扑
    topology = _build_topology_from_edges(constellation_name, isl_pairs)

    # 2. 构造 ISL 物理链路序列
    isl_series = _build_isl_series(
        positions, isl_pairs, isl_results_by_time, time_grid, topology;
        capacity_mbps = isl_capacity_mbps,
    )

    # 3. 构造接入决策表（max-elevation 策略）
    access_table = _build_access_table(
        gsl_avail_by_time, gsl_dist_by_time, gsl_elev_by_time,
        ground_ids, time_grid;
        capacity_mbps = gsl_capacity_mbps,
        gsl_delay_ms_by_time = gsl_delay_ms_by_time,
        handover_policy = handover_policy,
    )

    # 4. 调用完整 AON。
    #    capacity_aware=true 走准入控制；否则未传算法保持旧 shortest-delay 语义。
    if capacity_aware
        return evaluate_traffic_capacity_aware(
            demands, isl_series, access_table; admission_order = admission_order,
        )
    end
    return routing_algorithm === nothing ?
        evaluate_traffic(demands, isl_series, access_table) :
        evaluate_traffic(demands, isl_series, access_table, routing_algorithm)
end

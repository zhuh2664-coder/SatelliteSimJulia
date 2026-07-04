"""
    Energy Drain 攻击模块

本文件实现 Energy Drain 攻击：攻击者通过向特定地面端点注入大量攻击流量，
迫使数据包经过目标卫星，从而提升其通信功耗，加速电池耗尽。

# 主要流程
1. EnergyDrainAttackConfig 定义攻击参数（源/目的地面端点、起止时间、速率等）。
2. energy_drain_attack_demands 生成对应的 TrafficDemand 列表。
3. score_energy_drain_attack_endpoints 枚举候选端点对，
   复用 traffic.jl 与 energy.jl 的评估逻辑，计算哪一对端点能给目标卫星带来最大通信能耗暴露。
4. 选定的攻击端点可转换回 EnergyDrainAttackConfig，用于后续注入基线流量并观察电池 SOC 变化。

# 依赖模块
- core/orbit_layer/time.jl：SimulationTimeGrid、timeslot_offsets、time_count
- core/network_layer/links.jl：ISLPhysicalLinkSeries
- core/network_layer/access.jl：AccessDecisionTable、access_decisions_for_ground
- core/network_layer/routing.jl：RoutePath
- core/traffic_layer/traffic.jl：TrafficDemand、TrafficEvaluation、evaluate_traffic、
  traffic_assignments_at
- core/traffic_layer/energy.jl：CommunicationPowerModel、SatelliteCommunicationLoadSeries、
  evaluate_satellite_communication_loads、satellite_communication_loads_at
"""

"""
    EnergyDrainAttackConfig

Energy Drain 攻击的配置参数。

# 字段
- `id_start::Int`：攻击流量的需求 ID 起始值，默认 1_000_000，用于避免与基线需求冲突。
- `source_ground_ids::Vector{Int}`：攻击源地面端点编号集合。
- `destination_ground_ids::Vector{Int}`：攻击目的地面端点编号集合。
- `start_elapsed_s::Int`：攻击开始时刻（相对仿真起点的秒数，含）。
- `end_elapsed_s::Int`：攻击结束时刻（相对仿真起点的秒数，不含）。
- `rate_mbps::Float64`：每条攻击流的速率（Mbps）。
- `flows_per_pair::Int`：每对源/目的端点之间注入的并行流数量，默认 1。
"""
struct EnergyDrainAttackConfig
    id_start::Int
    source_ground_ids::Vector{Int}
    destination_ground_ids::Vector{Int}
    start_elapsed_s::Int
    end_elapsed_s::Int
    rate_mbps::Float64
    flows_per_pair::Int

    function EnergyDrainAttackConfig(;
        id_start::Int = 1_000_000,
        source_ground_ids::Vector{Int},
        destination_ground_ids::Vector{Int},
        start_elapsed_s::Int,
        end_elapsed_s::Int,
        rate_mbps::Real,
        flows_per_pair::Int = 1,
    )
        id_start > 0 || throw(ArgumentError("id_start must be positive"))
        !isempty(source_ground_ids) ||
            throw(ArgumentError("source_ground_ids must not be empty"))
        !isempty(destination_ground_ids) ||
            throw(ArgumentError("destination_ground_ids must not be empty"))
        all(id -> id > 0, source_ground_ids) ||
            throw(ArgumentError("source_ground_ids must be positive"))
        all(id -> id > 0, destination_ground_ids) ||
            throw(ArgumentError("destination_ground_ids must be positive"))
        length(unique(source_ground_ids)) == length(source_ground_ids) ||
            throw(ArgumentError("source_ground_ids must be unique"))
        length(unique(destination_ground_ids)) == length(destination_ground_ids) ||
            throw(ArgumentError("destination_ground_ids must be unique"))
        start_elapsed_s >= 0 ||
            throw(ArgumentError("start_elapsed_s must be non-negative"))
        end_elapsed_s > start_elapsed_s ||
            throw(ArgumentError("end_elapsed_s must be greater than start_elapsed_s"))
        rate_mbps >= 0 || throw(ArgumentError("rate_mbps must be non-negative"))
        flows_per_pair > 0 || throw(ArgumentError("flows_per_pair must be positive"))
        any(source != destination for source in source_ground_ids for destination in destination_ground_ids) ||
            throw(ArgumentError("attack must contain at least one source/destination pair"))
        return new(
            id_start,
            copy(source_ground_ids),
            copy(destination_ground_ids),
            start_elapsed_s,
            end_elapsed_s,
            Float64(rate_mbps),
            flows_per_pair,
        )
    end
end

"""
    EnergyDrainAttackEndpointScore

描述一对地面端点作为 Energy Drain 攻击端点评分结果。

# 字段
- `source_ground_id::Int`：攻击源地面端点编号。
- `destination_ground_id::Int`：攻击目的地面端点编号。
- `target_satellite_id::Int`：被判定为受影响最大的目标卫星编号。
- `reachable_assignments::Int`：攻击流在仿真时段内成功可达的分配次数。
- `dropped_mbps::Float64`：因路径不可达等原因被丢弃的攻击流量总和（Mbps）。
- `target_communication_load_w_s::Float64`：目标卫星因攻击新增的通信能耗暴露（W·s）。
- `total_communication_load_w_s::Float64`：所有卫星因攻击新增的通信能耗暴露总和（W·s）。
- `peak_target_communication_load_w::Float64`：目标卫星在任意时隙达到的最大通信功耗（W）。

# 说明
评分按 `(目标能耗暴露, 总能耗暴露, 丢弃流量, ...)` 降序/升序排序，
帮助攻击者选择“性价比”最高的端点对。
"""
struct EnergyDrainAttackEndpointScore
    source_ground_id::Int
    destination_ground_id::Int
    target_satellite_id::Int
    reachable_assignments::Int
    dropped_mbps::Float64
    target_communication_load_w_s::Float64
    total_communication_load_w_s::Float64
    peak_target_communication_load_w::Float64

    function EnergyDrainAttackEndpointScore(;
        source_ground_id::Int,
        destination_ground_id::Int,
        target_satellite_id::Int,
        reachable_assignments::Int,
        dropped_mbps::Real,
        target_communication_load_w_s::Real,
        total_communication_load_w_s::Real,
        peak_target_communication_load_w::Real,
    )
        source_ground_id > 0 || throw(ArgumentError("source_ground_id must be positive"))
        destination_ground_id > 0 || throw(ArgumentError("destination_ground_id must be positive"))
        source_ground_id != destination_ground_id ||
            throw(ArgumentError("source and destination ground ids must differ"))
        target_satellite_id > 0 || throw(ArgumentError("target_satellite_id must be positive"))
        reachable_assignments >= 0 ||
            throw(ArgumentError("reachable_assignments must be non-negative"))
        dropped_mbps >= 0 || throw(ArgumentError("dropped_mbps must be non-negative"))
        target_communication_load_w_s >= 0 ||
            throw(ArgumentError("target_communication_load_w_s must be non-negative"))
        total_communication_load_w_s >= 0 ||
            throw(ArgumentError("total_communication_load_w_s must be non-negative"))
        peak_target_communication_load_w >= 0 ||
            throw(ArgumentError("peak_target_communication_load_w must be non-negative"))
        return new(
            source_ground_id,
            destination_ground_id,
            target_satellite_id,
            reachable_assignments,
            Float64(dropped_mbps),
            Float64(target_communication_load_w_s),
            Float64(total_communication_load_w_s),
            Float64(peak_target_communication_load_w),
        )
    end
end

"""
    energy_drain_attack_demands(config)::Vector{TrafficDemand}

根据攻击配置生成对应的攻击业务需求列表。

对 `source_ground_ids` 与 `destination_ground_ids` 做笛卡尔积，
跳过源/目的相同的无效组合；每对端点按 `flows_per_pair` 生成多条独立需求，
需求 ID 从 `id_start` 开始递增。
"""
function energy_drain_attack_demands(config::EnergyDrainAttackConfig)::Vector{TrafficDemand}
    demands = TrafficDemand[]
    next_id = config.id_start
    for source_ground_id in config.source_ground_ids
        for destination_ground_id in config.destination_ground_ids
            source_ground_id == destination_ground_id && continue
            for _ in 1:config.flows_per_pair
                push!(
                    demands,
                    TrafficDemand(
                        id = next_id,
                        source_ground_id = source_ground_id,
                        destination_ground_id = destination_ground_id,
                        start_elapsed_s = config.start_elapsed_s,
                        end_elapsed_s = config.end_elapsed_s,
                        rate_mbps = config.rate_mbps,
                    ),
                )
                next_id += 1
            end
        end
    end
    return demands
end

"""
    inject_energy_drain_attack(baseline_demands, config)::Vector{TrafficDemand}

将攻击需求拼接到基线需求之后，返回合并后的需求列表。

# 说明
会检查攻击需求 ID 与基线需求 ID 是否重复，防止 ID 冲突。
"""
function inject_energy_drain_attack(
    baseline_demands::Vector{TrafficDemand},
    config::EnergyDrainAttackConfig,
)::Vector{TrafficDemand}
    attack_demands = energy_drain_attack_demands(config)
    combined = vcat(baseline_demands, attack_demands)
    length(unique(demand.id for demand in combined)) == length(combined) ||
        throw(ArgumentError("attack demand ids overlap with baseline demand ids"))
    return combined
end

"""
    attack_slot_durations_s(time_grid)::Vector{Int}

计算每个时隙的持续时间（秒）。

最后一个时隙的持续时间设为 0，因为该时隙仅用于快照，不再向下推进电池状态。
"""
function attack_slot_durations_s(time_grid::SimulationTimeGrid)::Vector{Int}
    offsets = timeslot_offsets(time_grid)
    return [
        time_index == length(offsets) ? 0 : offsets[time_index + 1] - offsets[time_index]
        for time_index in eachindex(offsets)
    ]
end

"""
    communication_exposure_by_satellite(loads)::Vector{Float64}

计算每颗卫星在整个仿真时段内的通信能耗暴露（W·s）。

将每个时隙的通信功耗（W）乘以该时隙持续时间（s）后累加。
最后一个时隙持续时间为 0，因此只贡献快照功耗但不累积能量。
"""
function communication_exposure_by_satellite(
    loads::SatelliteCommunicationLoadSeries,
)::Vector{Float64}
    exposure = zeros(Float64, loads.satellite_count)
    durations_s = attack_slot_durations_s(loads.time_grid)
    for time_index in 1:time_count(loads.time_grid)
        duration_s = durations_s[time_index]
        duration_s > 0 || continue
        for sample in satellite_communication_loads_at(loads, time_index)
            exposure[sample.satellite_id] += sample.communication_load_w * duration_s
        end
    end
    return exposure
end

"""
    peak_communication_load_by_satellite(loads)::Vector{Float64}

计算每颗卫星在整个仿真时段内达到的最大通信功耗（W）。
"""
function peak_communication_load_by_satellite(
    loads::SatelliteCommunicationLoadSeries,
)::Vector{Float64}
    peaks = zeros(Float64, loads.satellite_count)
    for time_index in 1:time_count(loads.time_grid)
        for sample in satellite_communication_loads_at(loads, time_index)
            peaks[sample.satellite_id] = max(peaks[sample.satellite_id], sample.communication_load_w)
        end
    end
    return peaks
end

"""
    reachable_assignment_count(evaluation)::Int

统计 `TrafficEvaluation` 中路由可达的分配总数。
"""
function reachable_assignment_count(evaluation::TrafficEvaluation)::Int
    return sum(
        assignment.route.reachable ? 1 : 0
        for time_index in 1:time_count(evaluation.time_grid)
        for assignment in traffic_assignments_at(evaluation, time_index)
    )
end

"""
    dropped_mbps_sum(evaluation)::Float64

计算 `TrafficEvaluation` 中所有被丢弃流量的总和（Mbps）。
"""
function dropped_mbps_sum(evaluation::TrafficEvaluation)::Float64
    return sum(
        assignment.dropped_mbps
        for time_index in 1:time_count(evaluation.time_grid)
        for assignment in traffic_assignments_at(evaluation, time_index)
    )
end

"""
    ground_ids(access_table)::Vector{Int}

从接入决策表中提取所有地面端点编号，并排序返回。
"""
function ground_ids(access_table::AccessDecisionTable)::Vector{Int}
    return sort([series.ground_id for series in access_table.series_by_ground])
end

"""
    score_energy_drain_attack_endpoints(isl_series, access_table, satellite_count; kwargs...)::Vector{EnergyDrainAttackEndpointScore}

枚举候选地面端点对，评估并排序哪一对端点能给目标卫星带来最大能耗影响。

# 参数
- `isl_series::ISLPhysicalLinkSeries`：ISL 物理链路时序样本。
- `access_table::AccessDecisionTable`：地面端点接入决策表。
- `satellite_count::Int`：卫星总数。
- `candidate_ground_ids::Union{Nothing,Vector{Int}}`：候选地面端点；默认取接入表中所有端点。
- `target_satellite_id::Union{Nothing,Int}`：指定目标卫星；未指定时选择能耗暴露最大的卫星。
- `start_elapsed_s::Int`：攻击开始时间，默认 0。
- `end_elapsed_s::Int`：攻击结束时间，默认 `isl_series.time_grid.duration_s`。
- `rate_mbps::Real`：每条攻击流速率（必填）。
- `flows_per_pair::Int`：每对端点的并行流数，默认 1。
- `id_start::Int`：攻击需求 ID 起始值，默认 1_000_000。
- `power_model::CommunicationPowerModel`：通信功耗模型，默认新建。

# 返回
- 按攻击效果排序的 `EnergyDrainAttackEndpointScore` 向量。
  排序键依次为：目标能耗暴露降序、总能耗暴露降序、丢弃流量升序、端点/目标 ID 升序。

# 依赖
- `energy_drain_attack_demands`、`evaluate_traffic`、`evaluate_satellite_communication_loads`
- `communication_exposure_by_satellite`、`peak_communication_load_by_satellite`
- `reachable_assignment_count`、`dropped_mbps_sum`
"""
function score_energy_drain_attack_endpoints(
    isl_series::ISLPhysicalLinkSeries,
    access_table::AccessDecisionTable,
    satellite_count::Int;
    candidate_ground_ids::Union{Nothing,Vector{Int}} = nothing,
    target_satellite_id::Union{Nothing,Int} = nothing,
    start_elapsed_s::Int = 0,
    end_elapsed_s::Int = isl_series.time_grid.duration_s,
    rate_mbps::Real,
    flows_per_pair::Int = 1,
    id_start::Int = 1_000_000,
    power_model::CommunicationPowerModel = CommunicationPowerModel(),
)::Vector{EnergyDrainAttackEndpointScore}
    isl_series.time_grid === access_table.time_grid ||
        throw(ArgumentError("ISL series and access table must share the same time_grid object"))
    satellite_count > 0 || throw(ArgumentError("satellite_count must be positive"))
    target_satellite_id === nothing || 1 <= target_satellite_id <= satellite_count ||
        throw(ArgumentError("target_satellite_id must be within satellite_count"))
    candidates = candidate_ground_ids === nothing ? ground_ids(access_table) : copy(candidate_ground_ids)
    length(unique(candidates)) == length(candidates) ||
        throw(ArgumentError("candidate_ground_ids must be unique"))
    # 验证所有候选端点都存在于接入决策表中。
    for ground_id in candidates
        access_decisions_for_ground(access_table, ground_id)
    end

    scores = EnergyDrainAttackEndpointScore[]
    next_id = id_start
    for source_ground_id in candidates
        for destination_ground_id in candidates
            source_ground_id == destination_ground_id && continue
            config = EnergyDrainAttackConfig(
                id_start = next_id,
                source_ground_ids = [source_ground_id],
                destination_ground_ids = [destination_ground_id],
                start_elapsed_s = start_elapsed_s,
                end_elapsed_s = end_elapsed_s,
                rate_mbps = rate_mbps,
                flows_per_pair = flows_per_pair,
            )
            demands = energy_drain_attack_demands(config)
            next_id += length(demands)
            # 复用流量层与能耗层评估逻辑：先算分配与链路负载，再算卫星通信功耗。
            evaluation = evaluate_traffic(demands, isl_series, access_table)
            loads = evaluate_satellite_communication_loads(evaluation, satellite_count, power_model)
            exposure = communication_exposure_by_satellite(loads)
            peaks = peak_communication_load_by_satellite(loads)
            # 若未指定目标卫星，则自动选择通信能耗暴露最大的卫星。
            selected_target_id = target_satellite_id === nothing ?
                argmax(exposure) :
                target_satellite_id
            push!(
                scores,
                EnergyDrainAttackEndpointScore(
                    source_ground_id = source_ground_id,
                    destination_ground_id = destination_ground_id,
                    target_satellite_id = selected_target_id,
                    reachable_assignments = reachable_assignment_count(evaluation),
                    dropped_mbps = dropped_mbps_sum(evaluation),
                    target_communication_load_w_s = exposure[selected_target_id],
                    total_communication_load_w_s = sum(exposure),
                    peak_target_communication_load_w = peaks[selected_target_id],
                ),
            )
        end
    end

    return sort(
        scores;
        by = score -> (
            -score.target_communication_load_w_s,
            -score.total_communication_load_w_s,
            score.dropped_mbps,
            score.source_ground_id,
            score.destination_ground_id,
            score.target_satellite_id,
        ),
    )
end

"""
    select_energy_drain_attack_endpoint(isl_series, access_table, satellite_count; kwargs...)::EnergyDrainAttackEndpointScore

返回评分最高的攻击端点对。

若没有任何候选，则抛出 `ArgumentError`。
"""
function select_energy_drain_attack_endpoint(
    isl_series::ISLPhysicalLinkSeries,
    access_table::AccessDecisionTable,
    satellite_count::Int;
    kwargs...,
)::EnergyDrainAttackEndpointScore
    scores = score_energy_drain_attack_endpoints(
        isl_series,
        access_table,
        satellite_count;
        kwargs...,
    )
    isempty(scores) && throw(ArgumentError("no valid attack endpoint candidates"))
    return first(scores)
end

"""
    energy_drain_attack_config_from_score(score; id_start, start_elapsed_s, end_elapsed_s, rate_mbps, flows_per_pair)::EnergyDrainAttackConfig

将评分结果转换回 `EnergyDrainAttackConfig`，便于复用端点选择结果生成正式攻击流量。

# 说明
评分结果中只记录单个源/目的端点，因此生成的配置中源/目的集合各含一个元素。
"""
function energy_drain_attack_config_from_score(
    score::EnergyDrainAttackEndpointScore;
    id_start::Int = 1_000_000,
    start_elapsed_s::Int,
    end_elapsed_s::Int,
    rate_mbps::Real,
    flows_per_pair::Int = 1,
)::EnergyDrainAttackConfig
    return EnergyDrainAttackConfig(
        id_start = id_start,
        source_ground_ids = [score.source_ground_id],
        destination_ground_ids = [score.destination_ground_id],
        start_elapsed_s = start_elapsed_s,
        end_elapsed_s = end_elapsed_s,
        rate_mbps = rate_mbps,
        flows_per_pair = flows_per_pair,
    )
end

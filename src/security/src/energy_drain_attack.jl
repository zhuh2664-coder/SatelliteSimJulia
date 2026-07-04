# ===== Energy Drain 攻击 =====
#
# 迁移自 legacy/layers/08_security/energy_drain.jl。
# 攻击者通过向特定地面端点注入大量攻击流量，迫使数据包经过目标卫星，
# 提升其通信功耗，加速电池耗尽。
#
# 修复点（探索点 3，组5不兼容）：删除 legacy 本地 ground_ids 辅助函数，
# 改用 SatelliteSimNet 导出的 ground_ids。

using SatelliteSimTraffic: TrafficDemand, TrafficEvaluation, evaluate_traffic,
                           CommunicationPowerModel, SatelliteCommunicationLoadSeries,
                           evaluate_satellite_communication_loads,
                           satellite_communication_loads_at
using SatelliteSimLink: ISLPhysicalLinkSeries
using SatelliteSimNet: AccessDecisionTable, access_decisions_for_ground, ground_ids
using SatelliteSimFoundation: SimulationTimeGrid, timeslot_offsets, time_count

export EnergyDrainAttackConfig, EnergyDrainAttackEndpointScore,
       energy_drain_attack_demands, inject_energy_drain_attack,
       score_energy_drain_attack_endpoints, select_energy_drain_attack_endpoint,
       energy_drain_attack_config_from_score,
       communication_exposure_by_satellite, peak_communication_load_by_satellite

"""
    EnergyDrainAttackConfig <: AbstractNetworkAttack

Energy Drain 攻击配置（流量注入型空间网络层攻击）。

# 字段
- `id_start::Int`：攻击流量需求 ID 起始值（默认 1_000_000，避免与基线冲突）
- `source_ground_ids::Vector{Int}`：攻击源地面端点
- `destination_ground_ids::Vector{Int}`：攻击目的地面端点
- `start_elapsed_s::Int`：攻击开始时刻（秒，含）
- `end_elapsed_s::Int`：攻击结束时刻（秒，不含）
- `rate_mbps::Float64`：每条攻击流速率
- `flows_per_pair::Int`：每对端点并行流数（默认 1）
"""
struct EnergyDrainAttackConfig <: AbstractNetworkAttack
    id_start::Int
    source_ground_ids::Vector{Int}
    destination_ground_ids::Vector{Int}
    start_elapsed_s::Int
    end_elapsed_s::Float64
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
            Float64(end_elapsed_s),
            Float64(rate_mbps),
            flows_per_pair,
        )
    end
end

"""
    EnergyDrainAttackEndpointScore

一对地面端点作为 Energy Drain 攻击端点的评分结果。

# 字段
- `source_ground_id::Int`：源端点
- `destination_ground_id::Int`：目的端点
- `target_satellite_id::Int`：受影响最大的目标卫星
- `reachable_assignments::Int`：可达分配次数
- `dropped_mbps::Float64`：丢弃流量总和
- `target_communication_load_w_s::Float64`：目标卫星新增通信能耗暴露（W·s）
- `total_communication_load_w_s::Float64`：所有卫星新增能耗总和
- `peak_target_communication_load_w::Float64`：目标卫星峰值通信功耗（W）
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
    energy_drain_attack_demands(config) -> Vector{TrafficDemand}

根据攻击配置生成攻击业务需求列表。
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
                        end_elapsed_s = Int(config.end_elapsed_s),
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
    inject_energy_drain_attack(baseline_demands, config) -> Vector{TrafficDemand}

将攻击需求拼接到基线需求之后。检查 ID 冲突。
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

# ── 内部辅助：能耗暴露统计 ──

"""计算每个时隙持续时间（最后一个时隙为 0，仅快照不累积）。"""
function attack_slot_durations_s(time_grid::SimulationTimeGrid)::Vector{Int}
    offsets = timeslot_offsets(time_grid)
    return [
        time_index == length(offsets) ? 0 : offsets[time_index + 1] - offsets[time_index]
        for time_index in eachindex(offsets)
    ]
end

"""每颗卫星在整个仿真时段的通信能耗暴露（W·s）。"""
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

"""每颗卫星在整个仿真时段的最大通信功耗（W）。"""
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

reachable_assignment_count(evaluation::TrafficEvaluation)::Int = sum(
    assignment.route.reachable ? 1 : 0
    for time_index in 1:time_count(evaluation.time_grid)
    for assignment in SatelliteSimTraffic.traffic_assignments_at(evaluation, time_index)
)

dropped_mbps_sum(evaluation::TrafficEvaluation)::Float64 = sum(
    assignment.dropped_mbps
    for time_index in 1:time_count(evaluation.time_grid)
    for assignment in SatelliteSimTraffic.traffic_assignments_at(evaluation, time_index)
)

"""
    score_energy_drain_attack_endpoints(isl_series, access_table, satellite_count; kwargs...) -> Vector{EnergyDrainAttackEndpointScore}

枚举候选地面端点对，评估并排序哪一对能给目标卫星带来最大能耗影响。
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
            evaluation = evaluate_traffic(demands, isl_series, access_table)
            loads = evaluate_satellite_communication_loads(evaluation, satellite_count, power_model)
            exposure = communication_exposure_by_satellite(loads)
            peaks = peak_communication_load_by_satellite(loads)
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
    select_energy_drain_attack_endpoint(isl_series, access_table, satellite_count; kwargs...) -> EnergyDrainAttackEndpointScore

返回评分最高的攻击端点对。
"""
function select_energy_drain_attack_endpoint(
    isl_series::ISLPhysicalLinkSeries,
    access_table::AccessDecisionTable,
    satellite_count::Int;
    kwargs...,
)::EnergyDrainAttackEndpointScore
    scores = score_energy_drain_attack_endpoints(isl_series, access_table, satellite_count; kwargs...)
    isempty(scores) && throw(ArgumentError("no valid attack endpoint candidates"))
    return first(scores)
end

"""
    energy_drain_attack_config_from_score(score; kwargs...) -> EnergyDrainAttackConfig

将评分结果转回 EnergyDrainAttackConfig，便于复用端点选择。
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

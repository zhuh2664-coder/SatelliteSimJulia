"""
    能耗层核心模块

本文件实现能耗层的核心功能：将 traffic.jl 输出的链路负载映射为卫星通信功耗，
并基于简化的电池模型推进卫星电源状态。

# 线性功耗模型（Linear Power Consumption Model）
#
# 卫星通信功耗采用简化的线性折算模型：
#   P_comm = λ_GSL · L_GSL + λ_ISL_TX · L_ISL_TX + λ_ISL_RX · L_ISL_RX
#
# 其中：
#   - λ_GSL：GSL 功耗系数（W/Mbps），默认 0.02 W/Mbps
#   - λ_ISL_TX：ISL 发送端功耗系数，默认 0.01 W/Mbps
#   - λ_ISL_RX：ISL 接收端功耗系数，默认 0.01 W/Mbps
#   - L_GSL：该卫星所有 GSL 链路的总负载（Mbps）
#   - L_ISL_TX：该卫星作为发送端的所有 ISL 负载之和
#   - L_ISL_RX：该卫星作为接收端的所有 ISL 负载之和
#
# 这种线性模型是对实际非线性功放效率的简化。
# 实际系统中，功放效率随输出功率变化（通常在 30%-50% 之间），
# 且不同调制编码方案（MCS）有不同的功率效率。
# 线性模型适用于初步评估和优化阶段。

# 电池荷电状态（SOC）演化模型
#
# 卫星电池 SOC（State of Charge）定义为：
#   SOC = E_stored / E_capacity  ∈ [0, 1]
#
# 电池状态演化（欧拉前向积分）：
#   ΔE = P_net · Δt / 3600   （Wh）
#   其中 P_net = P_solar - P_total
#   P_total = P_base + P_payload + P_comm
#
# 电池储能钳制：
#   E_stored(t+1) = clamp(E_stored(t) + ΔE, 0, E_capacity)
#
# 太阳能发电 vs 负载平衡：
#   - 日照期（in_eclipse = false）：P_solar > 0，电池充电
#   - 食影期（in_eclipse = true）：P_solar = 0，电池放电
#   - 净功率为正 → 充电；净功率为负 → 放电
#   - 当 SOC = 0 时（depleted = true），卫星可能失去通信能力

# 依赖模块
- core/orbit_layer/time.jl：SimulationTimeGrid、timeslot_offsets、time_count
- core/orbit_layer/states.jl：PowerState、SatelliteRuntimeState、SatelliteStateTable、
  runtime_state、update_power_state!、total_load_w、state_of_charge
- core/traffic_layer/traffic.jl：TrafficEvaluation、traffic_assignments_at
"""

"""
    CommunicationPowerModel

卫星通信功耗的线性折算模型。

# 功耗计算公式
#   P_comm = gsl_w_per_mbps × L_GSL + isl_tx_w_per_mbps × L_ISL_TX + isl_rx_w_per_mbps × L_ISL_RX
#
# 物理含义：
#   - GSL 功耗（上行/下行）：地面站与卫星之间的链路，通常功率较高（波束成形、
#     功率放大等），因此默认系数（0.02 W/Mbps）高于 ISL。
#   - ISL 发送功耗：激光/微波链路的发送端，需要驱动发射机。
#   - ISL 接收功耗：接收端需要低噪声放大器（LNA）等。
#
# 为什么 ISL TX 和 RX 系数不同：
#   实际系统中，发射端需要高功率放大器（HPA），而接收端只需低功耗 LNA。
#   但为简化模型，这里默认两者相同（均为 0.01 W/Mbps）。
#   用户可通过配置调整系数以反映不同技术方案。

# 字段
- `gsl_w_per_mbps::Float64`：每 Mbps GSL 负载对应的功耗系数（W/Mbps），默认 0.02。
- `isl_tx_w_per_mbps::Float64`：每 Mbps ISL 发送负载对应的功耗系数（W/Mbps），默认 0.01。
- `isl_rx_w_per_mbps::Float64`：每 Mbps ISL 接收负载对应的功耗系数（W/Mbps），默认 0.01。

# 说明
通信功耗按三类负载的加权和计算，未考虑非线性功放效率、调制编码差异等细节。
"""
struct CommunicationPowerModel
    gsl_w_per_mbps::Float64
    isl_tx_w_per_mbps::Float64
    isl_rx_w_per_mbps::Float64

    function CommunicationPowerModel(;
        gsl_w_per_mbps::Real = 0.02,
        isl_tx_w_per_mbps::Real = 0.01,
        isl_rx_w_per_mbps::Real = 0.01,
    )
        gsl_w_per_mbps >= 0 ||
            throw(ArgumentError("gsl_w_per_mbps must be non-negative"))
        isl_tx_w_per_mbps >= 0 ||
            throw(ArgumentError("isl_tx_w_per_mbps must be non-negative"))
        isl_rx_w_per_mbps >= 0 ||
            throw(ArgumentError("isl_rx_w_per_mbps must be non-negative"))
        return new(
            Float64(gsl_w_per_mbps),
            Float64(isl_tx_w_per_mbps),
            Float64(isl_rx_w_per_mbps),
        )
    end
end

"""
    SatelliteCommunicationLoadSample

描述一颗卫星在某个时隙上的通信负载与对应功耗。

# 字段
- `satellite_id::Int`：卫星编号。
- `time_index::Int`：时隙索引。
- `elapsed_s::Int`：该时隙对应的仿真已运行秒数。
- `gsl_load_mbps::Float64`：该星上所有 GSL 链路的总负载（Mbps）。
- `isl_tx_load_mbps::Float64`：该星作为发送端的 ISL 总负载（Mbps）。
- `isl_rx_load_mbps::Float64`：该星作为接收端的 ISL 总负载（Mbps）。
- `communication_load_w::Float64`：由 CommunicationPowerModel 折算后的通信功耗（W）。
"""
struct SatelliteCommunicationLoadSample
    satellite_id::Int
    time_index::Int
    elapsed_s::Int
    gsl_load_mbps::Float64
    isl_tx_load_mbps::Float64
    isl_rx_load_mbps::Float64
    communication_load_w::Float64

    function SatelliteCommunicationLoadSample(;
        satellite_id::Int,
        time_index::Int,
        elapsed_s::Int,
        gsl_load_mbps::Real = 0,
        isl_tx_load_mbps::Real = 0,
        isl_rx_load_mbps::Real = 0,
        communication_load_w::Real = 0,
    )
        satellite_id > 0 || throw(ArgumentError("satellite_id must be positive"))
        time_index > 0 || throw(ArgumentError("time_index must be positive"))
        elapsed_s >= 0 || throw(ArgumentError("elapsed_s must be non-negative"))
        gsl_load_mbps >= 0 || throw(ArgumentError("gsl_load_mbps must be non-negative"))
        isl_tx_load_mbps >= 0 ||
            throw(ArgumentError("isl_tx_load_mbps must be non-negative"))
        isl_rx_load_mbps >= 0 ||
            throw(ArgumentError("isl_rx_load_mbps must be non-negative"))
        communication_load_w >= 0 ||
            throw(ArgumentError("communication_load_w must be non-negative"))
        return new(
            satellite_id,
            time_index,
            elapsed_s,
            Float64(gsl_load_mbps),
            Float64(isl_tx_load_mbps),
            Float64(isl_rx_load_mbps),
            Float64(communication_load_w),
        )
    end
end

"""
    SatelliteCommunicationLoadSeries

按时间网格组织的每颗卫星通信负载序列。

# 字段
- `time_grid::SimulationTimeGrid`：时间网格。
- `satellite_count::Int`：卫星总数。
- `loads_by_time::Vector{Vector{SatelliteCommunicationLoadSample}}`：
  每个时隙包含 `satellite_count` 个卫星负载样本。
"""
struct SatelliteCommunicationLoadSeries
    time_grid::SimulationTimeGrid
    satellite_count::Int
    loads_by_time::Vector{Vector{SatelliteCommunicationLoadSample}}

    function SatelliteCommunicationLoadSeries(
        time_grid::SimulationTimeGrid,
        satellite_count::Int,
        loads_by_time::Vector{Vector{SatelliteCommunicationLoadSample}},
    )
        satellite_count > 0 || throw(ArgumentError("satellite_count must be positive"))
        length(loads_by_time) == time_count(time_grid) ||
            throw(ArgumentError("loads_by_time must match the time grid length"))
        for (time_index, samples) in pairs(loads_by_time)
            length(samples) == satellite_count ||
                throw(ArgumentError("each time slice must contain one sample per satellite"))
            for (satellite_id, sample) in pairs(samples)
                sample.satellite_id == satellite_id ||
                    throw(ArgumentError("sample order must match satellite_id"))
                sample.time_index == time_index ||
                    throw(ArgumentError("sample time_index must match time slice order"))
            end
        end
        return new(time_grid, satellite_count, loads_by_time)
    end
end

"""
    PowerStateSample

描述一颗卫星在某个时隙上的电源状态快照，便于后续分析与可视化。

# 电源状态变量关系
#   net_power_w = solar_generation_w - total_load_w
#   total_load_w = base_load_w + payload_load_w + communication_load_w
#   state_of_charge = stored_energy_wh / battery_capacity_wh  （若 battery_capacity_wh > 0）
#   depleted = (battery_capacity_wh > 0) && (stored_energy_wh <= 0)
#
# 注：net_power_w > 0 表示充电状态，< 0 表示放电状态。
#   SOC 仅反映当前时刻的相对储能，不反映充放电速率。

# 字段
- `satellite_id::Int`：卫星编号。
- `time_index::Int`：时隙索引。
- `elapsed_s::Int`：该时隙对应的仿真已运行秒数。
- `stored_energy_wh::Float64`：当前电池储能（Wh）。
- `state_of_charge::Union{Nothing,Float64}`：电池荷电状态（0–1）；若电池容量为 0 则为 `nothing`。
- `solar_generation_w::Float64`：太阳能发电功率（W）。
- `base_load_w::Float64`：平台基础功耗（W）。
- `payload_load_w::Float64`：载荷功耗（W）。
- `communication_load_w::Float64`：通信功耗（W）。
- `total_load_w::Float64`：总功耗（W）。
- `net_power_w::Float64`：净功率，即 `solar_generation_w - total_load_w`。
- `depleted::Bool`：当电池容量大于 0 且储能为 0 时为 true，表示电池耗尽。
"""
struct PowerStateSample
    satellite_id::Int
    time_index::Int
    elapsed_s::Int
    stored_energy_wh::Float64
    state_of_charge::Union{Nothing,Float64}
    solar_generation_w::Float64
    base_load_w::Float64
    payload_load_w::Float64
    communication_load_w::Float64
    total_load_w::Float64
    net_power_w::Float64
    depleted::Bool

    function PowerStateSample(;
        satellite_id::Int,
        time_index::Int,
        elapsed_s::Int,
        power::PowerState,
    )
        satellite_id > 0 || throw(ArgumentError("satellite_id must be positive"))
        time_index > 0 || throw(ArgumentError("time_index must be positive"))
        elapsed_s >= 0 || throw(ArgumentError("elapsed_s must be non-negative"))
        total = total_load_w(power)
        net = power.solar_generation_w - total
        return new(
            satellite_id,
            time_index,
            elapsed_s,
            power.stored_energy_wh,
            state_of_charge(power),
            power.solar_generation_w,
            power.base_load_w,
            power.payload_load_w,
            power.communication_load_w,
            total,
            net,
            power.battery_capacity_wh > 0 && power.stored_energy_wh <= 0,
        )
    end
end

"""
    PowerStateSeries

按时间网格组织的每颗卫星电源状态序列。

# 字段
- `time_grid::SimulationTimeGrid`：时间网格。
- `satellite_count::Int`：卫星总数。
- `states_by_time::Vector{Vector{PowerStateSample}}`：
  每个时隙包含 `satellite_count` 个电源状态样本。
"""
struct PowerStateSeries
    time_grid::SimulationTimeGrid
    satellite_count::Int
    states_by_time::Vector{Vector{PowerStateSample}}

    function PowerStateSeries(
        time_grid::SimulationTimeGrid,
        satellite_count::Int,
        states_by_time::Vector{Vector{PowerStateSample}},
    )
        satellite_count > 0 || throw(ArgumentError("satellite_count must be positive"))
        length(states_by_time) == time_count(time_grid) ||
            throw(ArgumentError("states_by_time must match the time grid length"))
        for (time_index, samples) in pairs(states_by_time)
            length(samples) == satellite_count ||
                throw(ArgumentError("each time slice must contain one sample per satellite"))
            for (satellite_id, sample) in pairs(samples)
                sample.satellite_id == satellite_id ||
                    throw(ArgumentError("sample order must match satellite_id"))
                sample.time_index == time_index ||
                    throw(ArgumentError("sample time_index must match time slice order"))
            end
        end
        return new(time_grid, satellite_count, states_by_time)
    end
end

"""
    satellite_communication_loads_at(series, time_index)::Vector{SatelliteCommunicationLoadSample}

获取指定时隙的所有卫星通信负载样本。
"""
satellite_communication_loads_at(
    series::SatelliteCommunicationLoadSeries,
    time_index::Int,
)::Vector{SatelliteCommunicationLoadSample} = series.loads_by_time[time_index]

"""
    power_states_at(series, time_index)::Vector{PowerStateSample}

获取指定时隙的所有电源状态样本。
"""
power_states_at(series::PowerStateSeries, time_index::Int)::Vector{PowerStateSample} =
    series.states_by_time[time_index]

"""
    communication_load_w(model, gsl_load_mbps, isl_tx_load_mbps, isl_rx_load_mbps)::Float64

根据线性功耗模型，将 GSL/ISL 负载折算为通信功耗（W）。
"""
function communication_load_w(
    model::CommunicationPowerModel,
    gsl_load_mbps::Float64,
    isl_tx_load_mbps::Float64,
    isl_rx_load_mbps::Float64,
)::Float64
    return gsl_load_mbps * model.gsl_w_per_mbps +
           isl_tx_load_mbps * model.isl_tx_w_per_mbps +
           isl_rx_load_mbps * model.isl_rx_w_per_mbps
end

"""
    build_satellite_communication_load_samples(time_index, elapsed_s, gsl_loads, isl_tx_loads, isl_rx_loads, model)::Vector{SatelliteCommunicationLoadSample}

由每类负载向量构造该时隙所有卫星的 `SatelliteCommunicationLoadSample`。
"""
function build_satellite_communication_load_samples(
    time_index::Int,
    elapsed_s::Int,
    gsl_loads::Vector{Float64},
    isl_tx_loads::Vector{Float64},
    isl_rx_loads::Vector{Float64},
    model::CommunicationPowerModel,
)::Vector{SatelliteCommunicationLoadSample}
    return [
        begin
            watts = communication_load_w(
                model,
                gsl_loads[satellite_id],
                isl_tx_loads[satellite_id],
                isl_rx_loads[satellite_id],
            )
            SatelliteCommunicationLoadSample(
                satellite_id = satellite_id,
                time_index = time_index,
                elapsed_s = elapsed_s,
                gsl_load_mbps = gsl_loads[satellite_id],
                isl_tx_load_mbps = isl_tx_loads[satellite_id],
                isl_rx_load_mbps = isl_rx_loads[satellite_id],
                communication_load_w = watts,
            )
        end
        for satellite_id in eachindex(gsl_loads)
    ]
end

"""
    add_satellite_load!(loads, satellite_id, load_mbps)

将 `load_mbps` 累加到指定卫星的负载向量位置。
使用 `checkbounds` 保证索引安全。
"""
function add_satellite_load!(loads::Vector{Float64}, satellite_id::Int, load_mbps::Float64)::Nothing
    checkbounds(loads, satellite_id)
    loads[satellite_id] += load_mbps
    return nothing
end

"""
    evaluate_satellite_communication_loads(evaluation, satellite_count, model = CommunicationPowerModel())::SatelliteCommunicationLoadSeries

将 `TrafficEvaluation` 中的分配结果映射为每颗卫星的通信负载与功耗。

# 参数
- `evaluation::TrafficEvaluation`：流量评估结果。
- `satellite_count::Int`：卫星总数，决定输出负载向量的长度。
- `model::CommunicationPowerModel`：通信功耗线性模型。

# 返回
- `SatelliteCommunicationLoadSeries`：每个时隙每颗星的通信负载与功耗。

# 说明
仅处理 `carried_mbps > 0` 且路由可达的分配。GSL 负载分别计入源/目的接入星，
ISL 负载按 `satellite_path` 顺序拆分为发送端与接收端负载。
"""
function evaluate_satellite_communication_loads(
    evaluation::TrafficEvaluation,
    satellite_count::Int,
    model::CommunicationPowerModel = CommunicationPowerModel(),
)::SatelliteCommunicationLoadSeries
    satellite_count > 0 || throw(ArgumentError("satellite_count must be positive"))
    loads_by_time = Vector{Vector{SatelliteCommunicationLoadSample}}()

    for time_index in 1:time_count(evaluation.time_grid)
        elapsed_s = timeslot_offsets(evaluation.time_grid)[time_index]
        gsl_loads = zeros(Float64, satellite_count)
        isl_tx_loads = zeros(Float64, satellite_count)
        isl_rx_loads = zeros(Float64, satellite_count)

        for assignment in traffic_assignments_at(evaluation, time_index)
            assignment.carried_mbps > 0 || continue
            route = assignment.route
            route.reachable || continue
            source_satellite_id = route.source_access_satellite_id
            destination_satellite_id = route.destination_access_satellite_id
            # 可达路径必须提供接入星；若缺失则视为数据不一致。
            source_satellite_id === nothing &&
                throw(ArgumentError("reachable route is missing source access satellite"))
            destination_satellite_id === nothing &&
                throw(ArgumentError("reachable route is missing destination access satellite"))

            carried_mbps = assignment.carried_mbps
            # 源、目的卫星各承担一次上行/下行 GSL 负载。
            add_satellite_load!(gsl_loads, source_satellite_id, carried_mbps)
            add_satellite_load!(gsl_loads, destination_satellite_id, carried_mbps)

            # 沿卫星路径逐跳拆分 ISL 发送/接收负载。
            for index in 1:(length(route.satellite_path) - 1)
                tx_satellite_id = route.satellite_path[index]
                rx_satellite_id = route.satellite_path[index + 1]
                add_satellite_load!(isl_tx_loads, tx_satellite_id, carried_mbps)
                add_satellite_load!(isl_rx_loads, rx_satellite_id, carried_mbps)
            end
        end

        push!(
            loads_by_time,
            build_satellite_communication_load_samples(
                time_index,
                elapsed_s,
                gsl_loads,
                isl_tx_loads,
                isl_rx_loads,
                model,
            ),
        )
    end

    return SatelliteCommunicationLoadSeries(evaluation.time_grid, satellite_count, loads_by_time)
end

"""
    power_with_communication_load(power, communication_load_w)::PowerState

返回一个将通信功耗替换为 `communication_load_w` 后的新 `PowerState`，
用于在电池推进前把当前时隙的通信负载注入电源状态。
"""
function power_with_communication_load(power::PowerState, communication_load_w::Float64)::PowerState
    return PowerState(
        battery_capacity_wh = power.battery_capacity_wh,
        stored_energy_wh = power.stored_energy_wh,
        solar_generation_w = power.solar_generation_w,
        base_load_w = power.base_load_w,
        payload_load_w = power.payload_load_w,
        communication_load_w = communication_load_w,
        in_eclipse = power.in_eclipse,
    )
end

"""
    evolve_power_state(power, duration_s)::PowerState

根据净功率推进电源状态 `duration_s` 秒。

# 电池状态演化算法（欧拉前向积分）
#
# 物理模型：
#   dE/dt = P_solar(t) - P_load(t)
#
# 离散化（欧拉前向）：
#   E(t+Δt) = E(t) + (P_solar - P_load) × Δt / 3600
#
# 其中：
#   - E：电池储能（Wh）
#   - P_solar：太阳能发电功率（W）
#   - P_load：总负载功率（W），= base + payload + communication
#   - Δt：时间步长（秒）
#   - 除以 3600 将 W·s 转换为 Wh
#
# 边界条件（能量钳制）：
#   E(t+Δt) = clamp(E(t) + ΔE, 0, E_capacity)
#   - 下界 0：电池不能放电到负值（depleted 状态）
#   - 上界 E_capacity：电池不能过充（防止安全隐患）
#
# 为什么不用更精确的积分方法（如 RK4）：
#   时间步长（时隙间隔）通常为 60-300 秒，远小于轨道周期（~5400 秒），
#   欧拉前向方法的精度在此尺度下足够，且计算开销极低。

# 说明
- 净功率 = 太阳能发电 - 总负载。
- 能量变化按 `Wh = W * s / 3600` 计算。
- 电池储能被钳制在 `[0, battery_capacity_wh]` 范围内。
"""
function evolve_power_state(power::PowerState, duration_s::Real)::PowerState
    duration_s >= 0 || throw(ArgumentError("duration_s must be non-negative"))
    net_energy_wh = (power.solar_generation_w - total_load_w(power)) * Float64(duration_s) / 3600.0
    stored_energy_wh = clamp(
        power.stored_energy_wh + net_energy_wh,
        0.0,
        power.battery_capacity_wh,
    )
    return PowerState(
        battery_capacity_wh = power.battery_capacity_wh,
        stored_energy_wh = stored_energy_wh,
        solar_generation_w = power.solar_generation_w,
        base_load_w = power.base_load_w,
        payload_load_w = power.payload_load_w,
        communication_load_w = power.communication_load_w,
        in_eclipse = power.in_eclipse,
    )
end

"""
    apply_communication_loads!(table, samples)::SatelliteStateTable

将一组卫星通信负载样本写入 `SatelliteStateTable` 中对应卫星的电源状态。
返回修改后的状态表。
"""
function apply_communication_loads!(
    table::SatelliteStateTable,
    samples::Vector{SatelliteCommunicationLoadSample},
)::SatelliteStateTable
    for sample in samples
        checkbounds(table.states, sample.satellite_id)
        current = runtime_state(table, sample.satellite_id)
        update_power_state!(
            table,
            sample.satellite_id,
            power_with_communication_load(current.power, sample.communication_load_w),
        )
    end
    return table
end

"""
    apply_communication_loads!(table, series, time_index)::SatelliteStateTable

将 `series` 中指定时隙的通信负载应用到状态表。
"""
function apply_communication_loads!(
    table::SatelliteStateTable,
    series::SatelliteCommunicationLoadSeries,
    time_index::Int,
)::SatelliteStateTable
    length(table) >= series.satellite_count ||
        throw(ArgumentError("state table must contain at least series.satellite_count states"))
    return apply_communication_loads!(table, satellite_communication_loads_at(series, time_index))
end

"""
    snapshot_power_states(table, time_index, elapsed_s, satellite_count = length(table))::Vector{PowerStateSample}

从状态表中提取指定数量的卫星电源状态快照。
"""
function snapshot_power_states(
    table::SatelliteStateTable,
    time_index::Int,
    elapsed_s::Int,
    satellite_count::Int = length(table),
)::Vector{PowerStateSample}
    satellite_count > 0 || throw(ArgumentError("satellite_count must be positive"))
    length(table) >= satellite_count ||
        throw(ArgumentError("state table must contain at least satellite_count states"))
    return [
        PowerStateSample(
            satellite_id = satellite_id,
            time_index = time_index,
            elapsed_s = elapsed_s,
            power = runtime_state(table, satellite_id).power,
        )
        for satellite_id in 1:satellite_count
    ]
end

"""
    simulate_power_states(initial_states, communication_loads)::PowerStateSeries

根据初始电源状态与通信负载序列，模拟整个仿真时段的电池状态变化。

# 仿真流程
# 1. 复制初始状态（避免修改调用方数据）
# 2. 对每个时隙 i 执行：
#    a. 注入通信负载：将该时隙的 communication_load_w 写入 PowerState
#    b. 拍摄快照：记录当前电源状态（SOC、净功率、是否耗尽等）
#    c. 推进电池状态：用当前时隙与下一时隙的时间差 Δt = offsets[i+1] - offsets[i]
#       调用 evolve_power_state 推进电池储能
# 3. 最后一个时隙之后不再推进（因为没有下一时隙）
#
# 时间线示例（3 个时隙）：
#   t0=0s: 注入负载 → 快照 → 推进 Δt1 到 t1
#   t1=60s: 注入负载 → 快照 → 推进 Δt2 到 t2
#   t2=120s: 注入负载 → 快照 → 结束
#
# 这种"先注入、后推进"的顺序确保每个快照反映的是注入负载后的状态。

# 参数
- `initial_states::SatelliteStateTable`：所有卫星的初始运行时状态。
- `communication_loads::SatelliteCommunicationLoadSeries`：通信负载序列。

# 返回
- `PowerStateSeries`：每个时隙每颗星的电源状态快照。
"""
function simulate_power_states(
    initial_states::SatelliteStateTable,
    communication_loads::SatelliteCommunicationLoadSeries,
)::PowerStateSeries
    length(initial_states) >= communication_loads.satellite_count ||
        throw(ArgumentError("initial_states must contain at least communication_loads.satellite_count states"))
    # 复制初始状态，避免修改调用方传入的状态表。
    table = SatelliteStateTable([
        SatelliteRuntimeState(
            satellite_id = state.satellite_id,
            status = state.status,
            power = state.power,
            communication = state.communication,
        )
        for state in initial_states.states
    ])
    states_by_time = Vector{Vector{PowerStateSample}}()
    offsets = timeslot_offsets(communication_loads.time_grid)

    for time_index in 1:time_count(communication_loads.time_grid)
        apply_communication_loads!(table, communication_loads, time_index)
        elapsed_s = offsets[time_index]
        push!(
            states_by_time,
            snapshot_power_states(table, time_index, elapsed_s, communication_loads.satellite_count),
        )

        # 最后一个时隙之后没有后续时间差，无需推进电池状态。
        time_index == time_count(communication_loads.time_grid) && continue
        duration_s = offsets[time_index + 1] - offsets[time_index]
        for satellite_id in 1:communication_loads.satellite_count
            current = runtime_state(table, satellite_id)
            update_power_state!(table, satellite_id, evolve_power_state(current.power, duration_s))
        end
    end

    return PowerStateSeries(
        communication_loads.time_grid,
        communication_loads.satellite_count,
        states_by_time,
    )
end

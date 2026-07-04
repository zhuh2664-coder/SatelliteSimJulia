# ===== 卫星通信功耗模型 =====
#
# 迁移自 legacy/layers/05_traffic/energy.jl 的通信负载部分（8 个符号）。
# 电源状态推进部分（PowerState/evolve_power_state/simulate_power_states）依赖
# core/src/layers/01_orbit/states.jl（当前为孤立死代码，未 include），
# 故本文件暂不迁移，待 states.jl 正式接入后再补。
#
# 线性功耗模型：
#   P_comm = λ_GSL · L_GSL + λ_ISL_TX · L_ISL_TX + λ_ISL_RX · L_ISL_RX
#   λ_GSL=0.02, λ_ISL_TX=0.01, λ_ISL_RX=0.01 (W/Mbps)
#
# 本模块被 SatelliteSimSecurity 的 energy_drain 攻击依赖（攻击者通过注入流量
# 抬升目标卫星通信功耗，加速电池耗尽）。

export CommunicationPowerModel,
       SatelliteCommunicationLoadSample, SatelliteCommunicationLoadSeries,
       satellite_communication_loads_at, communication_load_w,
       build_satellite_communication_load_samples,
       evaluate_satellite_communication_loads

"""
    CommunicationPowerModel

卫星通信功耗的线性折算模型。

# 字段
- `gsl_w_per_mbps::Float64`：每 Mbps GSL 负载对应的功耗系数（W/Mbps），默认 0.02
- `isl_tx_w_per_mbps::Float64`：每 Mbps ISL 发送负载对应的功耗系数，默认 0.01
- `isl_rx_w_per_mbps::Float64`：每 Mbps ISL 接收负载对应的功耗系数，默认 0.01
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

一颗卫星在某个时隙上的通信负载与对应功耗。

# 字段
- `satellite_id::Int`：卫星编号
- `time_index::Int`：时隙索引
- `elapsed_s::Int`：该时隙对应的仿真已运行秒数
- `gsl_load_mbps::Float64`：该星所有 GSL 链路总负载（Mbps）
- `isl_tx_load_mbps::Float64`：该星作为发送端的 ISL 总负载（Mbps）
- `isl_rx_load_mbps::Float64`：该星作为接收端的 ISL 总负载（Mbps）
- `communication_load_w::Float64`：由 CommunicationPowerModel 折算的通信功耗（W）
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
- `time_grid::SimulationTimeGrid`：时间网格
- `satellite_count::Int`：卫星总数
- `loads_by_time::Vector{Vector{SatelliteCommunicationLoadSample}}`：每时隙每星一个样本
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
    satellite_communication_loads_at(series, time_index)

获取指定时隙的所有卫星通信负载样本。
"""
satellite_communication_loads_at(
    series::SatelliteCommunicationLoadSeries,
    time_index::Int,
)::Vector{SatelliteCommunicationLoadSample} = series.loads_by_time[time_index]

"""
    communication_load_w(model, gsl_load_mbps, isl_tx_load_mbps, isl_rx_load_mbps) -> Float64

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
    add_satellite_load!(loads, satellite_id, load_mbps)

将 load_mbps 累加到指定卫星的负载向量位置（内部辅助）。
"""
function add_satellite_load!(loads::Vector{Float64}, satellite_id::Int, load_mbps::Float64)::Nothing
    checkbounds(loads, satellite_id)
    loads[satellite_id] += load_mbps
    return nothing
end

"""
    build_satellite_communication_load_samples(time_index, elapsed_s, gsl_loads, isl_tx_loads, isl_rx_loads, model)

由每类负载向量构造该时隙所有卫星的 SatelliteCommunicationLoadSample。
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
    evaluate_satellite_communication_loads(evaluation, satellite_count, model=CommunicationPowerModel()) -> SatelliteCommunicationLoadSeries

将 TrafficEvaluation 中的分配结果映射为每颗卫星的通信负载与功耗。

仅处理 carried_mbps > 0 且路由可达的分配。GSL 负载计入源/目的接入星，
ISL 负载按 satellite_path 顺序拆分为发送端与接收端负载。
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
            source_satellite_id === nothing &&
                throw(ArgumentError("reachable route is missing source access satellite"))
            destination_satellite_id === nothing &&
                throw(ArgumentError("reachable route is missing destination access satellite"))

            carried_mbps = assignment.carried_mbps
            add_satellite_load!(gsl_loads, source_satellite_id, carried_mbps)
            add_satellite_load!(gsl_loads, destination_satellite_id, carried_mbps)

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

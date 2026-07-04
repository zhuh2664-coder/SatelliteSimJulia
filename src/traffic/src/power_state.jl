# ===== 电池 SOC 演化模型 =====
#
# 消费 SatelliteCommunicationLoadSeries（通信功耗 W）+ 太阳能输入，
# 推进电池荷电状态（SOC, State of Charge）时间序列。
#
# 之前 energy.jl 只到通信功耗折算，电源状态推进部分因依赖死代码未迁移。
# 本文件独立实现电池 SOC 演化，不依赖任何 legacy 代码。
#
# 新增于 2026-07-04（Phase 2 - A4）。

using SatelliteSimFoundation: SimulationTimeGrid, timeslot_offsets, time_count

export
    PowerState,
    SolarPowerProfile,
    UniformSolar,
    EclipseSolar,
    PowerStateSeries,
    evolve_power_states,
    initial_power_state

# ────────────────────────────────────────────────────────────
# 电池状态
# ────────────────────────────────────────────────────────────

"""
    PowerState

电池荷电状态快照。

# 字段
- `satellite_id::Int`: 卫星编号
- `time_index::Int`: 时隙索引
- `elapsed_s::Int`: 该时隙对应的仿真秒数
- `soc::Float64`: 荷电状态（0.0-1.0，0=空，1=满）
- `energy_wh::Float64`: 当前储能（Wh）
- `charge_w::Float64`: 该时隙充电功率（W，正=太阳能>消耗）
- `discharge_w::Float64`: 该时隙放电功率（W，正=消耗>太阳能）
- `in_eclipse::Bool`: 该时隙是否在日食期
- `solar_input_w::Float64`: 太阳能板输入功率（W）
- `comm_load_w::Float64`: 通信功耗（W）
"""
struct PowerState
    satellite_id::Int
    time_index::Int
    elapsed_s::Int
    soc::Float64
    energy_wh::Float64
    charge_w::Float64
    discharge_w::Float64
    in_eclipse::Bool
    solar_input_w::Float64
    comm_load_w::Float64
end

"""
    PowerStateSeries

所有卫星在所有时隙上的电池状态序列。
"""
struct PowerStateSeries
    time_grid::SimulationTimeGrid
    satellite_count::Int
    states_by_time::Vector{Vector{PowerState}}
end

# ────────────────────────────────────────────────────────────
# 太阳能输入模型
# ────────────────────────────────────────────────────────────

"""
    AbstractSolarProfile

太阳能输入随时间变化的抽象接口。
"""
abstract type AbstractSolarProfile end

"""
    UniformSolar

恒定太阳能输入（简化模型，无日食）。

# 字段
- `solar_power_w::Float64`: 太阳能板稳态输出功率（W），典型 LEO 卫星 ~500-2000W
"""
struct UniformSolar <: AbstractSolarProfile
    solar_power_w::Float64
end

"""
    EclipseSolar

带日食期调制的太阳能输入。

LEO 卫星在轨道运行中会进入地球阴影（日食），太阳能中断。
本模型用正弦近似日食周期：日照期太阳能 = solar_power_w，
日食期太阳能 = 0，按 eclipse_period_min 周期切换。

# 字段
- `solar_power_w::Float64`: 日照期太阳能板输出（W）
- `eclipse_period_min::Float64`: 日食周期（分钟），典型 LEO ~95 分钟/圈
- `eclipse_fraction::Float64`: 日食占周期比例（0-1），典型 LEO ~0.35
- `phase_offset_min::Float64`: 相位偏移（分钟），对齐不同卫星
"""
struct EclipseSolar <: AbstractSolarProfile
    solar_power_w::Float64
    eclipse_period_min::Float64
    eclipse_fraction::Float64
    phase_offset_min::Float64
end

EclipseSolar(;
    solar_power_w::Float64 = 800.0,
    eclipse_period_min::Float64 = 95.0,
    eclipse_fraction::Float64 = 0.35,
    phase_offset_min::Float64 = 0.0,
) = EclipseSolar(solar_power_w, eclipse_period_min, eclipse_fraction, phase_offset_min)

"""
    solar_power_w(profile, elapsed_s) -> (power_w, in_eclipse)

查询某时刻的太阳能输入功率（W）和是否在日食期。
"""
function solar_power_w end

solar_power_w(p::UniformSolar, elapsed_s::Int) = (p.solar_power_w, false)

function solar_power_w(p::EclipseSolar, elapsed_s::Int)
    period_s = p.eclipse_period_min * 60.0
    phase_s = p.phase_offset_min * 60.0
    # 周期内位置 [0, period_s)
    cycle_pos = mod(elapsed_s + phase_s, period_s)
    eclipse_duration = period_s * p.eclipse_fraction
    # 日食期在周期前段
    if cycle_pos < eclipse_duration
        return (0.0, true)
    else
        return (p.solar_power_w, false)
    end
end

# ────────────────────────────────────────────────────────────
# SOC 演化
# ────────────────────────────────────────────────────────────

"""
    initial_power_state(satellite_id; capacity_wh, initial_soc) -> PowerState

构造初始满电状态（time_index=0, elapsed_s=0）。
"""
function initial_power_state(;
    satellite_id::Int,
    capacity_wh::Float64,
    initial_soc::Float64 = 1.0,
)::PowerState
    0.0 <= initial_soc <= 1.0 || throw(ArgumentError("initial_soc must be in [0,1]"))
    return PowerState(
        satellite_id, 0, 0,
        initial_soc,
        capacity_wh * initial_soc,
        0.0, 0.0, false, 0.0, 0.0,
    )
end

"""
    _evolve_one_step(prev, dt_s, solar, comm_load_w, capacity_wh, charge_eff, discharge_eff)

单步推进一颗卫星的电池状态。

# 物理模型
- 净功率 = 太阳能 - 通信功耗（简化：忽略其他功耗如姿控/热控/TT&C 的恒定基底）
- 净功率 > 0：充电（考虑充电效率 η_c）
- 净功率 < 0：放电（考虑放电效率 η_d）
- SOC 裁剪到 [0, 1]
"""
function _evolve_one_step(
    prev::PowerState,
    dt_s::Float64,
    solar::AbstractSolarProfile,
    comm_load_w::Float64,
    capacity_wh::Float64,
    charge_eff::Float64,
    discharge_eff::Float64,
)::PowerState
    # 太阳能输入
    (solar_w, in_eclipse) = solar_power_w(solar, prev.elapsed_s + Int(round(dt_s / 2)))
    # 净功率（W）
    net_w = solar_w - comm_load_w
    # 能量变化（Wh）= 功率(W) × 时间(h)
    dt_h = dt_s / 3600.0
    if net_w >= 0
        # 充电（考虑效率）
        delta_wh = net_w * dt_h * charge_eff
        charge_w = net_w
        discharge_w = 0.0
    else
        # 放电（考虑效率：电池放 ΔW 供负载用，损耗 1/η_d）
        delta_wh = net_w * dt_h / discharge_eff
        charge_w = 0.0
        discharge_w = -net_w
    end
    # 更新储能，裁剪到 [0, capacity]
    new_energy = clamp(prev.energy_wh + delta_wh, 0.0, capacity_wh)
    new_soc = new_energy / capacity_wh
    return PowerState(
        prev.satellite_id,
        prev.time_index + 1,
        prev.elapsed_s + Int(round(dt_s)),
        new_soc,
        new_energy,
        charge_w,
        discharge_w,
        in_eclipse,
        solar_w,
        comm_load_w,
    )
end

"""
    evolve_power_states(
        load_series::SatelliteCommunicationLoadSeries,
        capacity_wh, solar_profile;
        initial_soc, charge_eff, discharge_eff
    ) -> PowerStateSeries

推进所有卫星的电池 SOC 时间序列。

# 参数
- `load_series`: 通信功耗序列（来自 evaluate_satellite_communication_loads）
- `capacity_wh::Float64`: 电池容量（Wh），典型 CubeSat ~50-200Wh
- `solar_profile::AbstractSolarProfile`: 太阳能输入模型
- `initial_soc::Float64`: 初始 SOC（默认 1.0 满电）
- `charge_eff::Float64`: 充电效率（默认 0.9）
- `discharge_eff::Float64`: 放电效率（默认 0.95）

# 返回
- `PowerStateSeries`: 每时隙每卫星的 PowerState
"""
function evolve_power_states(
    load_series::SatelliteCommunicationLoadSeries,
    capacity_wh::Float64,
    solar_profile::AbstractSolarProfile = UniformSolar(800.0);
    initial_soc::Float64 = 1.0,
    charge_eff::Float64 = 0.9,
    discharge_eff::Float64 = 0.95,
)::PowerStateSeries
    capacity_wh > 0 || throw(ArgumentError("capacity_wh must be positive"))
    n_sat = load_series.satellite_count
    n_time = time_count(load_series.time_grid)
    offsets = timeslot_offsets(load_series.time_grid)

    # 初始状态
    states = [initial_power_state(;
        satellite_id = sat,
        capacity_wh = capacity_wh,
        initial_soc = initial_soc,
    ) for sat in 1:n_sat]

    states_by_time = Vector{Vector{PowerState}}()
    # 第一个时隙就是初始状态快照
    push!(states_by_time, copy(states))

    # 逐步推进
    for t in 2:n_time
        dt_s = Float64(offsets[t] - offsets[t-1])
        dt_s > 0 || (push!(states_by_time, copy(states)); continue)
        new_states = PowerState[]
        for sat in 1:n_sat
            comm_load = load_series.loads_by_time[t-1][sat].communication_load_w
            new_state = _evolve_one_step(
                states[sat], dt_s, solar_profile, comm_load,
                capacity_wh, charge_eff, discharge_eff,
            )
            push!(new_states, new_state)
        end
        states = new_states
        push!(states_by_time, copy(states))
    end

    return PowerStateSeries(load_series.time_grid, n_sat, states_by_time)
end

"""
    evolve_power_states_const_load(
        satellite_count, time_grid, comm_load_w, capacity_wh, solar_profile;
        initial_soc, charge_eff, discharge_eff
    ) -> PowerStateSeries

简化版：所有卫星恒定通信功耗（不用 TrafficEvaluation，便于快速测试）。
"""
function evolve_power_states_const_load(
    satellite_count::Int,
    time_grid::SimulationTimeGrid,
    comm_load_w::Float64,
    capacity_wh::Float64,
    solar_profile::AbstractSolarProfile = UniformSolar(800.0);
    initial_soc::Float64 = 1.0,
    charge_eff::Float64 = 0.9,
    discharge_eff::Float64 = 0.95,
)::PowerStateSeries
    # 构造假 load series
    n_time = time_count(time_grid)
    fake_loads = [
        [SatelliteCommunicationLoadSample(;
            satellite_id = sat, time_index = t,
            elapsed_s = timeslot_offsets(time_grid)[t],
            gsl_load_mbps = 0.0, isl_tx_load_mbps = 0.0, isl_rx_load_mbps = 0.0,
            communication_load_w = comm_load_w,
        ) for sat in 1:satellite_count]
        for t in 1:n_time
    ]
    fake_series = SatelliteCommunicationLoadSeries(time_grid, satellite_count, fake_loads)
    return evolve_power_states(fake_series, capacity_wh, solar_profile;
        initial_soc = initial_soc, charge_eff = charge_eff, discharge_eff = discharge_eff)
end

abstract type EnergySource end

mutable struct LiIonBattery <: EnergySource
    capacity::Float64          # Wh
    voltage_nominal::Float64   # V
    soc::Float64               # State of Charge 0.0-1.0
    current_draw::Float64
    internal_resistance::Float64
    cycle_count::Int
    temperature::Float64
end

LiIonBattery(;cap=500.0, volt=28.0, soc0=1.0, res=0.05) =
    LiIonBattery(cap, volt, soc0, 0.0, res, 0, 20.0)

remaining_energy(b::LiIonBattery) = b.capacity * b.soc
remaining_pct(b::LiIonBattery) = b.soc * 100.0

function discharge!(b::LiIonBattery, power_w::Float64, dt::Float64)
    e = power_w * dt / 3600
    b.soc = max(0.0, b.soc - e / b.capacity)
    b.current_draw = power_w / b.voltage_nominal
end

function charge!(b::LiIonBattery, power_w::Float64, dt::Float64)
    e = power_w * dt / 3600
    b.soc = min(1.0, b.soc + e * 0.95 / b.capacity)
end

abstract type EnergyHarvester end

mutable struct SolarPanel <: EnergyHarvester
    area::Float64
    efficiency::Float64
    power_per_area::Float64  # W/m² AM0 ≈ 1367
    is_illuminated::Bool
end

SolarPanel(;area=5.0, eff=0.30) = SolarPanel(area, eff, 1367.0, true)

harvest_power(p::SolarPanel) = p.is_illuminated ? p.area * p.power_per_area * p.efficiency : 0.0

mutable struct SatelliteEnergyModel
    battery::LiIonBattery
    solar::SolarPanel
    power_compute::Float64
    power_isl_tx::Float64
    power_isl_rx::Float64
    power_gsl_tx::Float64
    power_gsl_rx::Float64
    power_bus::Float64
    isl_active::Int
    gsl_active::Bool
end

SatelliteEnergyModel(;comp=50.0, isl_tx=30.0, isl_rx=10.0,
                      gsl_tx=100.0, gsl_rx=20.0, bus=80.0) =
    SatelliteEnergyModel(LiIonBattery(), SolarPanel(),
                         comp, isl_tx, isl_rx, gsl_tx, gsl_rx, bus, 4, false)

total_power(em::SatelliteEnergyModel) =
    em.power_compute +
    em.isl_active * (em.power_isl_tx + em.power_isl_rx) +
    (em.gsl_active ? em.power_gsl_tx + em.power_gsl_rx : 0.0) +
    em.power_bus

function update_energy!(em::SatelliteEnergyModel, dt::Float64)
    t_mod = Now() % 5400
    em.solar.is_illuminated = t_mod < 3600
    sp = harvest_power(em.solar)
    if sp > 0; charge!(em.battery, sp, dt); end
    load = total_power(em)
    discharge!(em.battery, load, dt)
end

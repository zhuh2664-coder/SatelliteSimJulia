# ===== 卫星硬件配置 =====

export SatelliteConfig, DEFAULT_SAT_CONFIG, KUIPER_SAT_CONFIG

Base.@kwdef struct SatelliteConfig
    isl_antenna_count::Int = 4
    isl_range_km::Float64 = 5000.0
    laser_cone_angle_deg::Float64 = 60.0
    laser_azimuth_range_deg::Float64 = 180.0
    laser_setup_time_s::Float64 = 2.0
    storage_gb::Float64 = 100.0
    compute_flops::Float64 = 1e9
end

const DEFAULT_SAT_CONFIG = SatelliteConfig()

const KUIPER_SAT_CONFIG = SatelliteConfig(;
    isl_antenna_count = 4,
    isl_range_km = 5000.0,
    laser_cone_angle_deg = 60.0,
    laser_azimuth_range_deg = 180.0,
    laser_setup_time_s = 2.0,
    storage_gb = 200.0,
    compute_flops = 2e9,
)

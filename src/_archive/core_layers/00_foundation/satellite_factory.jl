# ===== 卫星构造器 =====

export SatelliteInstance, build_satellite

const LegacySatellite = LegacyEntities.Satellite
const LegacySatelliteState = LegacyEntities.SatelliteState

struct SatelliteInstance
    static::LegacySatellite
    state::LegacySatelliteState
end

"""
    build_satellite(id, hardware::SatelliteConfig, state::StateConfig) -> SatelliteInstance

Build a legacy `SatelliteInstance` from hardware and initial-state configs.
"""
function build_satellite(id::String, hardware::SatelliteConfig, state::StateConfig)
    static = LegacySatellite(
        id, nothing,
        hardware.isl_antenna_count,
        hardware.isl_range_km,
        hardware.laser_cone_angle_deg,
        hardware.laser_azimuth_range_deg,
        hardware.laser_setup_time_s,
        hardware.storage_gb,
        hardware.compute_flops,
    )
    state_obj = LegacySatelliteState(
        id,
        state.x, state.y, state.z,
        state.vx, state.vy, state.vz,
        state.status,
        Set{String}(),
    )
    return SatelliteInstance(static, state_obj)
end

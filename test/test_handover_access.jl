# ===== handover_policy 接入 access 主管线 =====

using Test
using SatelliteSimNet: NearestDistance, ElevationThreshold, select_satellite,
    build_access_decision_table
using SatelliteSimLink: GSLPhysicalLinkSample, LinkAvailable

@testset "handover policy selection" begin
    samples = [
        GSLPhysicalLinkSample{Float64}(;
            ground_id=1, satellite_id=1, time_index=1, elapsed_s=0,
            distance_km=1200.0, propagation_delay_s=0.004, elevation_deg=45.0,
            capacity_mbps=500.0, state=LinkAvailable(),
        ),
        GSLPhysicalLinkSample{Float64}(;
            ground_id=1, satellite_id=2, time_index=1, elapsed_s=0,
            distance_km=800.0, propagation_delay_s=0.003, elevation_deg=30.0,
            capacity_mbps=500.0, state=LinkAvailable(),
        ),
    ]

    elev_pick = select_satellite(ElevationThreshold(), samples)
    @test elev_pick.satellite_id == 1

    near_pick = select_satellite(NearestDistance(), samples)
    @test near_pick.satellite_id == 2
end

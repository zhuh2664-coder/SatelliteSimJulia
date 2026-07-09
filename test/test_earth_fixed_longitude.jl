# ===== EarthFixedOrbitElementSet 经度 API =====

using Test
using SatelliteSimOrbit: EarthFixedOrbitElementSet, earth_fixed_node_longitude_deg
using SatelliteSimFoundation: SourceMetadata

@testset "earth_fixed_node_longitude_deg" begin
    earth_fixed = EarthFixedOrbitElementSet(
        550.0, 53.0, 10.0, 0.0, SourceMetadata("earth-fixed"),
    )
    @test earth_fixed_node_longitude_deg(earth_fixed) ≈ 30.0

    inclined = EarthFixedOrbitElementSet(;
        altitude_km = 550,
        inclination_deg = 53,
        raan_deg = 10,
        argument_of_perigee_deg = 5,
        mean_anomaly_deg = 20,
    )
    @test earth_fixed_node_longitude_deg(inclined) ≈ 35.0
end

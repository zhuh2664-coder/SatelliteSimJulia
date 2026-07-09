# ===== weather 模块 smoke test =====

using Test
using SatelliteSimLink: link_budget, rain_attenuation_db, RainParameters

@testset "weather smoke" begin
    budget = link_budget(;
        tx_power_dbw=10.0,
        tx_antenna_gain_dbi=30.0,
        frequency_ghz=20.0,
        distance_km=500.0,
        rx_antenna_gain_dbi=35.0,
        system_noise_temp_k=150.0,
        bandwidth_hz=1e6,
        required_snr_db=5.0,
    )
    @test isfinite(budget.snr_db)
    @test isfinite(budget.cnr_db_hz)
    @test budget.rain_attenuation_db == 0.0

    rain = RainParameters(;
        latitude_deg=40.0,
        elevation_deg=30.0,
        frequency_ghz=20.0,
        rain_rate_mm_h=10.0,
    )
    atten = rain_attenuation_db(rain)
    @test isfinite(atten)
    @test atten >= 0.0
end

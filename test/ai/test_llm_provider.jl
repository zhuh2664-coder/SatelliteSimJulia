using Test
using SatelliteSimLab

@testset "LLM provider config" begin
    provider = SatelliteSimLab.LLMProvider(; key = "dummy", model = "GPT-5.5", url = "http://127.0.0.1:8317/v1", readtimeout_s = 300)
    @test provider.api_key == "dummy"
    @test provider.model == "GPT-5.5"
    @test provider.base_url == "http://127.0.0.1:8317/v1"
    @test provider.readtimeout_s == 300

    compat = SatelliteSimLab.LLMProvider("dummy", "model", "http://localhost/v1")
    @test compat.readtimeout_s == 120

    @test_throws ErrorException SatelliteSimLab.LLMProvider(; key = "dummy", readtimeout_s = 0)
end

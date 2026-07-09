# ===== 实验缓存 schema 校验 (H5) =====

using Test
using SatelliteSimLab: ExperimentConfig, config_hash, CACHE_SCHEMA_VERSION, cached_experiment, ExperimentResult
using SatelliteSimCore: WalkerConstellationConfig

@testset "cache validation" begin
    config_a = ExperimentConfig(
        name = "alpha",
        constellation = WalkerConstellationConfig(T=6, P=2, F=0, alt_km=550.0, inc_deg=53.0),
        tspan = [0.0, 30.0],
    )
    config_b = ExperimentConfig(
        name = "beta",
        constellation = WalkerConstellationConfig(T=6, P=2, F=0, alt_km=550.0, inc_deg=53.0),
        tspan = [0.0, 30.0],
    )
    @test config_hash(config_a) != config_hash(config_b)
    @test CACHE_SCHEMA_VERSION == 1

    h = config_hash(config_a)
    path = joinpath("data", "cache", "$(h).json")
    mkpath(dirname(path))
    backup = isfile(path) ? read(path, String) : nothing
    try
        open(path, "w") do io
            write(io, """{"cache_version":0,"coverage_ratio":0.5}""")
        end
        result = cached_experiment(config_a; force=false)
        @test result isa ExperimentResult
    finally
        if backup === nothing
            isfile(path) && rm(path; force=true)
        else
            open(path, "w") do io; write(io, backup); end
        end
    end
end

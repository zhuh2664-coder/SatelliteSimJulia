# ===== run_distributed_simulation multiprocess smoke =====

using Test
using SatelliteSimDistributed: run_distributed_simulation
using SatelliteSimLab: ExperimentConfig
using SatelliteSimNet: RingStrategy

@testset "run_distributed_simulation multiprocess" begin
    config = ExperimentConfig(
        name = "dist-smoke",
        constellation_params = Dict(
            :T => 4.0, :P => 2.0, :F => 0.0, :alt_km => 550.0, :inc_deg => 53.0,
        ),
        tspan = [0.0, 60.0],
        topology_strategy = RingStrategy(),
        propagator = :two_body,
    )
    result = run_distributed_simulation(config; n_workers=2)
    @test size(result.positions) == (4, 3)
    @test result.n_workers == 2
    @test all(isfinite, result.positions)
    @test result.D isa Matrix{Float64}
    @test size(result.D) == (4, 4)
end

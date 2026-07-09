# ===== SimulationTimeGrid 与 positions 时间维对齐 (H6) =====

using Test
using SatelliteSimLab
using SatelliteSimFoundation: time_count

@testset "SimulationTimeGrid alignment" begin
    config = ExperimentConfig(tspan = [0.0, 60.0, 120.0])
    grid = SatelliteSimLab._aligned_simulation_time_grid(config, 3)
    @test time_count(grid) == 3

    config2 = ExperimentConfig(tspan = [0.0, 10.0])
    grid2 = SatelliteSimLab._aligned_simulation_time_grid(config2, 5)
    @test time_count(grid2) == 5

    grid1 = SatelliteSimLab._aligned_simulation_time_grid(config2, 1)
    @test time_count(grid1) == 1
end

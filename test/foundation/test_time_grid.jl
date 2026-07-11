# test/foundation/test_time_grid.jl — 时间网格边界回归测试

using Dates
using Test

const FOUNDATION_TIME = SatelliteSimFoundation

@testset "SimulationTimeGrid includes exact and non-divisible endpoints" begin
    epoch = default_starlink_simulation_epoch()

    non_divisible = SimulationTimeGrid(epoch, 10, 3)
    @test non_divisible.epoch === epoch
    @test non_divisible.duration_s == 10
    @test non_divisible.step_s == 3
    @test timeslot_offsets(non_divisible) == [0, 3, 6, 9, 10]
    @test time_count(non_divisible) == 5

    divisible = SimulationTimeGrid(epoch, 12, 3)
    @test timeslot_offsets(divisible) == [0, 3, 6, 9, 12]
    @test time_count(divisible) == 5

    zero_duration = SimulationTimeGrid(epoch, 0, 60)
    @test timeslot_offsets(zero_duration) == [0]
    @test time_count(zero_duration) == 1
end

@testset "SimulationTimeGrid rejects invalid duration and step" begin
    epoch = default_starlink_simulation_epoch()

    @test_throws ArgumentError SimulationTimeGrid(epoch, -1, 60)
    @test_throws ArgumentError SimulationTimeGrid(epoch, 60, 0)
    @test_throws ArgumentError SimulationTimeGrid(epoch, 60, -1)
end

@testset "default Starlink epoch is stable" begin
    epoch = default_starlink_simulation_epoch()

    @test epoch.instant == DateTime(2026, 1, 1)
    @test FOUNDATION_TIME.simulation_epoch_year(epoch) == 26
    @test isapprox(FOUNDATION_TIME.simulation_epoch_day(epoch), 1.0; atol = 1e-12)
end

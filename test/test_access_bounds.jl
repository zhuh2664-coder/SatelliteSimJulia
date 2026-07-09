# ===== access_decisions_at 越界守卫 (M3) =====

using Test
using SatelliteSimCore
using SatelliteSimNet: AccessDecision, AccessDecisionTable, access_decisions_at

@testset "access time_index 越界" begin
    epoch = default_starlink_simulation_epoch()
    grid = SimulationTimeGrid(epoch, 6, 6)
    decisions = [
        AccessDecision(ground_id=1, time_index=1, selected_satellite_id=2, selected_sample=nothing),
        AccessDecision(ground_id=1, time_index=2, selected_satellite_id=3, selected_sample=nothing),
    ]
    table = AccessDecisionTable(grid, Dict(1 => decisions))

    ok = access_decisions_at(table, 1, 1)
    @test ok.selected_satellite_id == 2

    oob = access_decisions_at(table, 1, 99)
    @test oob.selected_satellite_id === nothing
    @test oob.ground_id == 1
    @test oob.time_index == 99

    missing_gs = access_decisions_at(table, 2, 1)
    @test missing_gs.selected_satellite_id === nothing
end

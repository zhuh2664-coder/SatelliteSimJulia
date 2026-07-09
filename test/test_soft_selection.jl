# ===== M9: soft_selection 数值稳定性 =====

using Test
using SatelliteSimOpt

@testset "soft_selection numerical guards" begin
    pos = [6000.0 0.0 0.0; 6001.0 0.0 0.0]
    ground = [6371.0 0.0 0.0]
    cell_ptr, dir, sat_of, npairs = SatelliteSimOpt.build_visibility(pos, ground; min_el=-90.0)
    @test cell_ptr[end] >= 1
    @test npairs >= 1

    ground_zero = [0.0 0.0 0.0]
    cell_ptr2, dir2, sat_of2, npairs2 = SatelliteSimOpt.build_visibility(pos, ground_zero; min_el=-90.0)
    @test npairs2 >= 0
    isempty(dir2) || @test all(isfinite, dir2)
end

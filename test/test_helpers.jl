# test/test_helpers.jl — 当前架构测试共享 fixture

using SatelliteSimJulia

"""
    make_walker_pos(T=24, P=6, F=1, t_slots=11)

生成一个 Walker delta 星座的 N×T×3 位置矩阵，供路由/链路测试复用。
"""
function make_walker_pos(T::Int=24, P::Int=6, F::Int=1, t_slots::Int=11)
    elems = generate_walker_delta(
        T = T,
        P = P,
        F = F,
        alt_km = 550.0,
        inc_deg = 53.0,
    )
    epoch = SimulationEpoch(DateTime(2026, 1, 1), TimeUTC)
    grid = SimulationTimeGrid(epoch, 60, t_slots)
    eph = propagate_constellation(elems, grid; propagator = :j2)
    return satellite_positions(eph)
end

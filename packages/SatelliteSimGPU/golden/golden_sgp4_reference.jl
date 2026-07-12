# Golden 参考：SGP4（近地）批量传播——直接委托 SatelliteToolbox 的 SGP4（NORAD/Vallado
# 权威实现），用作 `sgp4_propagate_gpu` 的对标基准。若上游 SGP4 语义变更，需同步本文件。
#
# 输入为每星"平均"根数 + bstar 与 tspan(min)；近地 SGP4 传播不依赖历元（历元仅深空用），
# 故固定一个任意历元 JD。输出 (N, T, 3) TEME 位置/速度，与 `sgp4_propagate_gpu` 布局对齐。

module GoldenSGP4Reference

using SatelliteToolbox: sgp4_init, sgp4!, sgp4c_wgs84

const _EPOCH_JD = 2.451545e6

"""批量 (N, T, 3) TEME 位置(km) 与速度(km/s)。元素长度 N（n₀ rad/min，角度 rad），tspan_min 长度 T。"""
function propagate_series(n₀, e₀, i₀, raan₀, argp₀, M₀, bstar, tspan_min)
    n_sat = length(n₀)
    n_times = length(tspan_min)
    positions = Array{Float64}(undef, n_sat, n_times, 3)
    velocities = Array{Float64}(undef, n_sat, n_times, 3)
    for s in 1:n_sat
        sgp4d = sgp4_init(
            _EPOCH_JD,
            Float64(n₀[s]), Float64(e₀[s]), Float64(i₀[s]),
            Float64(raan₀[s]), Float64(argp₀[s]), Float64(M₀[s]), Float64(bstar[s]);
            sgp4c=sgp4c_wgs84,
        )
        for (time_index, t) in enumerate(tspan_min)
            r, v = sgp4!(sgp4d, Float64(t))
            positions[s, time_index, 1] = r[1]
            positions[s, time_index, 2] = r[2]
            positions[s, time_index, 3] = r[3]
            velocities[s, time_index, 1] = v[1]
            velocities[s, time_index, 2] = v[2]
            velocities[s, time_index, 3] = v[3]
        end
    end
    return positions, velocities
end

end # module

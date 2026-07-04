# ===== 统一星座构造器 =====
# 从 catalog 配置 → Walker 传播 / TLE SGP4 → SatelliteInstance 列表。
# 依赖: catalog/constellations.jl, orbit/walker.jl, orbit/propagator.jl, core/factory.jl

using SatelliteToolbox
using SatelliteToolboxSgp4: sgp4_init, sgp4!

export build_constellation

"""
    build_constellation(config, tspan; hardware, propagator) -> Vector{SatelliteInstance}

统一星座构造。根据 `config[:source]` 自动选择构造路径:

- `:walker` → generate_walker_delta + propagate_to_ecef_with_vel
- `:tle`   → read_tles + sgp4_init/sgp4!

所有路径输出相同的 `Vector{SatelliteInstance}`。
"""
function build_constellation(config::Dict{Symbol,Any}, tspan::Vector{Float64};
    hardware::SatelliteConfig=DEFAULT_SAT_CONFIG,
    propagator::Symbol=:two_body,
)
    source = get(config, :source, :walker)

    if source == :walker
        return _build_from_walker(config, tspan; hardware=hardware, propagator=propagator)
    elseif source == :tle
        return _build_from_tle(config; hardware=hardware)
    else
        error("unknown constellation source: $source")
    end
end

# ═══════════════════════════════════════════════
# Walker 路径
# ═══════════════════════════════════════════════

function _build_from_walker(config::Dict{Symbol,Any}, tspan::Vector{Float64};
    hardware::SatelliteConfig, propagator::Symbol)
    T = Int(config[:T]); P = Int(config[:P]); F = Int(config[:F])
    alt_km = config[:alt_km]; inc_deg = config[:inc_deg]

    elems = generate_walker_delta(T=T, P=P, F=F, alt_km=alt_km, inc_deg=inc_deg)
    pos, vel = propagate_to_ecef_with_vel(elems, tspan; propagator=propagator)

    # 取初始帧位置速度
    t0 = 1
    sats = SatelliteInstance[]
    for i in 1:T
        state = StateConfig(;
            x=pos[i, t0, 1], y=pos[i, t0, 2], z=pos[i, t0, 3],
            vx=vel[i, t0, 1], vy=vel[i, t0, 2], vz=vel[i, t0, 3],
        )
        push!(sats, build_satellite("walker-$i", hardware, state))
    end
    return sats
end

# ═══════════════════════════════════════════════
# TLE 路径
# ═══════════════════════════════════════════════

function _build_from_tle(config::Dict{Symbol,Any}; hardware::SatelliteConfig)
    tle_path = config[:tle_path]
    content = read(tle_path, String)
    tles = SatelliteToolbox.read_tles(content)

    sats = SatelliteInstance[]
    for tle in tles
        orbp = sgp4_init(tle)
        r, v = sgp4!(orbp, 0.0)  # km, km/s (SatelliteToolboxSgp4 已返回 km)
        state = StateConfig(;
            x=r[1], y=r[2], z=r[3],
            vx=v[1], vy=v[2], vz=v[3],
        )
        id = "norad-$(tle.satellite_number)"
        push!(sats, build_satellite(id, hardware, state))
    end
    return sats
end

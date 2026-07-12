module SatelliteSimOrbit

using SatelliteSimFoundation
using SatelliteSimBackends

include("orbit_types.jl")
include("walker.jl")
include("propagator_two_body.jl")
include("backend_dispatch.jl")
include("propagator_sgp4.jl")
# HPOP 传播器需要 OrdinaryDiffEq，因版本兼容问题暂在实验脚本中直接使用
#include("propagator_hpop.jl")
include("ephemeris.jl")
include("tle_sources.jl")
include("omm_source.jl")
include("constellation_builder.jl")
include("accessors.jl")

end # module

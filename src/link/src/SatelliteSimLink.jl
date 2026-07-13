module SatelliteSimLink

using SatelliteSimFoundation
using SatelliteSimOrbit
using SatelliteSimBackends: CPUComputeBackend, GSLSeriesResult, ISLSeriesResult,
                            validate_gsl_series_result, validate_isl_series_result
using LinearAlgebra

import SatelliteSimFoundation: geodetic_to_ecef_km
import SatelliteSimBackends: compute_backend_cache_token,
                             compute_backend_capabilities,
                             compute_backend_fingerprint,
                             compute_backend_source_files, evaluate_gsl_series,
                             evaluate_isl_series

include("geometry.jl")
include("constraints.jl")
include("link_topology_types.jl")
include("link_models.jl")
include("evaluator.jl")
include("weather/rain_attenuation.jl")
include("weather/link_budget.jl")
include("weather/dvbs2_modcod.jl")
include("weather/weather_timeseries.jl")

end # module

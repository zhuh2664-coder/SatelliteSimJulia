using LinearAlgebra: norm
import SatelliteToolboxSgp4

export EndToEndGradientReport,
    EndToEndGradientConfig,
    fixture_gradient_tles,
    soft_route_loss,
    end_to_end_gradient_report

const E2E_SPEED_OF_LIGHT_KM_S = SatelliteSimFoundation.SPEED_OF_LIGHT_KM_S  # → Foundation/L0
const E2E_TLE_LINE1 = "1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753"
const E2E_TLE_LINE2S = [
    "2 00005  34.2682 331.5174 1859667 331.7664  19.3264 10.82419157413667",
    "2 00005  34.2682 341.5174 1859667 331.7664  49.3264 10.82419157413667",
    "2 00005  34.2682 351.5174 1859667 331.7664  79.3264 10.82419157413667",
]

struct EndToEndGradientConfig
    t_min::Float64
    distance_threshold_km::Float64
    temperature_km::Float64
    finite_difference_rel_step::Float64
end

struct EndToEndGradientReport
    loss::Float64
    n_params::Int
    grad_forward_norm::Float64
    grad_reverse_norm::Float64
    grad_finite_difference_norm::Float64
    max_relerr_forward_vs_fd::Float64
    max_relerr_reverse_vs_forward::Float64
    finite_forward::Bool
    finite_reverse::Bool
    finite_fd::Bool
end

function EndToEndGradientConfig(;
    t_min::Real = 60.0,
    distance_threshold_km::Real = 6000.0,
    temperature_km::Real = 400.0,
    finite_difference_rel_step::Real = 1e-6,
)
    t_min >= 0 || throw(ArgumentError("t_min must be non-negative"))
    distance_threshold_km > 0 || throw(ArgumentError("distance_threshold_km must be positive"))
    temperature_km > 0 || throw(ArgumentError("temperature_km must be positive"))
    finite_difference_rel_step > 0 ||
        throw(ArgumentError("finite_difference_rel_step must be positive"))
    return EndToEndGradientConfig(
        Float64(t_min),
        Float64(distance_threshold_km),
        Float64(temperature_km),
        Float64(finite_difference_rel_step),
    )
end

function fixture_gradient_tles()
    return [
        SatelliteToolboxSgp4.read_tle(E2E_TLE_LINE1, line2; verify_checksum=false)
        for line2 in E2E_TLE_LINE2S
    ]
end

function _finite_difference_gradient(f, x::Vector{Float64}; rel_step::Float64=1e-6)
    grad = similar(x)
    for i in eachindex(x)
        h = rel_step * max(abs(x[i]), 1.0)
        xp = copy(x)
        xm = copy(x)
        xp[i] += h
        xm[i] -= h
        grad[i] = (f(xp) - f(xm)) / (2h)
    end
    return grad
end

@inline function _flat_satellite_position(flat_positions::AbstractVector{T}, sat::Int) where T
    offset = 3 * (sat - 1)
    return (
        flat_positions[offset + 1],
        flat_positions[offset + 2],
        flat_positions[offset + 3],
    )
end

@inline function _flat_pair_distance_km(flat_positions::AbstractVector{T}, i::Int, j::Int) where T
    xi, yi, zi = _flat_satellite_position(flat_positions, i)
    xj, yj, zj = _flat_satellite_position(flat_positions, j)
    dx = xi - xj
    dy = yi - yj
    dz = zi - zj
    return sqrt(dx * dx + dy * dy + dz * dz)
end

function soft_route_loss(
    flat_positions::AbstractVector{T};
    distance_threshold_km::T = T(6000.0),
    temperature_km::T = T(400.0),
) where T <: Number
    d12 = _flat_pair_distance_km(flat_positions, 1, 2)
    d23 = _flat_pair_distance_km(flat_positions, 2, 3)
    d13 = _flat_pair_distance_km(flat_positions, 1, 3)

    a12 = one(T) / (one(T) + exp((d12 - distance_threshold_km) / temperature_km))
    a23 = one(T) / (one(T) + exp((d23 - distance_threshold_km) / temperature_km))
    a13 = one(T) / (one(T) + exp((d13 - distance_threshold_km) / temperature_km))

    direct_score = a13
    two_hop_score = a12 * a23
    path_score = one(T) - (one(T) - direct_score) * (one(T) - two_hop_score)

    direct_delay_ms = d13 / T(E2E_SPEED_OF_LIGHT_KM_S) * T(1000.0)
    two_hop_delay_ms = (d12 + d23) / T(E2E_SPEED_OF_LIGHT_KM_S) * T(1000.0)
    score_sum = direct_score + two_hop_score + T(1e-9)
    expected_delay_ms = (
        direct_score * direct_delay_ms +
        two_hop_score * two_hop_delay_ms
    ) / score_sum

    connectivity_penalty = (one(T) - path_score)^2
    return expected_delay_ms / T(1000.0) + T(10.0) * connectivity_penalty
end

function _relative_errors(a::AbstractVector, b::AbstractVector; floor::Float64=1e-9)
    return abs.(a .- b) ./ (abs.(b) .+ floor)
end

function end_to_end_gradient_report(
    tles = fixture_gradient_tles();
    config::EndToEndGradientConfig = EndToEndGradientConfig(),
)::EndToEndGradientReport
    loss_fn(pos) = soft_route_loss(
        pos;
        distance_threshold_km = eltype(pos)(config.distance_threshold_km),
        temperature_km = eltype(pos)(config.temperature_km),
    )

    params, epochs = _constellation_to_params(tles)
    loss_from_params(p) = begin
        T = eltype(p)
        pos = _propagate_constellation_from_params(p, epochs, T(config.t_min))
        loss_fn(pos)
    end

    loss_value = loss_from_params(params)
    grad_forward = constellation_gradient(tles, config.t_min, loss_fn; mode=:forward)
    grad_reverse = constellation_gradient(tles, config.t_min, loss_fn; mode=:reverse)
    grad_fd = _finite_difference_gradient(
        loss_from_params,
        params;
        rel_step = config.finite_difference_rel_step,
    )

    fd_rel = _relative_errors(grad_forward, grad_fd)
    reverse_rel = _relative_errors(grad_reverse, grad_forward)

    return EndToEndGradientReport(
        Float64(loss_value),
        length(params),
        norm(grad_forward),
        norm(grad_reverse),
        norm(grad_fd),
        maximum(fd_rel),
        maximum(reverse_rel),
        all(isfinite, grad_forward),
        all(isfinite, grad_reverse),
        all(isfinite, grad_fd),
    )
end

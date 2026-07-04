# Minimal probe: does gradient survive the chain
#     θ (orbital elements of satellite A)
#       -> sgp4! (EXISTING, already verified differentiable)
#       -> inter-satellite distance_km            (NEW: simple norm, mirrors links.jl)
#       -> propagation_delay_s = distance_km / c   (NEW: mirrors links.jl's constant)
#       -> visibility_score (smooth occlusion proxy) (NEW: mirrors optimization_layer/differentiable.jl's smooth_sigmoid)
#
# Goal: find out, with hard numbers, exactly where (if anywhere) the gradient
# goes to zero/NaN, so we know which pieces can stay in the differentiable
# pipeline as-is and which need a non-differentiable / alternative analysis path.
#
# Run with: julia --project=test test/test_pipeline_differentiability_probe.jl
import Pkg
Pkg.activate(@__DIR__; io = devnull)

using Test
using Printf
import ForwardDiff
import SatelliteToolboxSgp4
import LinearAlgebra: norm, dot

const D2R                 = π / 180
const REV_DAY_TO_RAD_MIN  = 2π / (24 * 60)

# Mirrors src/core/network_layer/links.jl (existing constants, duplicated here
# only because this probe runs in a standalone test environment that does not
# load the main package — see Project.toml note in test_sgp4_differentiability.jl).
const SPEED_OF_LIGHT_KM_S       = 299_792.458
const WGS84_EQUATORIAL_RADIUS_KM = 6378.137

# ---------------------------------------------------------------------------
# Fixture TLEs
#   Satellite A: VANGUARD 1 (same fixture as test_sgp4_differentiability.jl)
#   Satellite B: same TLE with RAAN shifted by 10 deg, used only to get a
#                second, distinct, *fixed* position to measure distance
#                against. B is treated as numeric/non-differentiated in this
#                probe — the point is to test the A-side gradient path first.
# ---------------------------------------------------------------------------
const TLE_LINE1_A = "1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753"
const TLE_LINE2_A = "2 00005  34.2682 331.5174 1859667 331.7664  19.3264 10.82419157413667"
const TLE_LINE2_B = "2 00005  34.2682 341.5174 1859667 331.7664  19.3264 10.82419157413667"

const TLE_A = SatelliteToolboxSgp4.read_tle(TLE_LINE1_A, TLE_LINE2_A; verify_checksum = false)
const TLE_B = SatelliteToolboxSgp4.read_tle(TLE_LINE1_A, TLE_LINE2_B; verify_checksum = false)

function fd_jacobian(f, x::AbstractVector{Float64}; h = 1e-6)
    y0 = f(x)
    n, m = length(x), length(y0)
    J = zeros(m, n)
    for i in 1:n
        xp = copy(x); xp[i] += h
        xm = copy(x); xm[i] -= h
        J[:, i] = (f(xp) .- f(xm)) ./ (2h)
    end
    return J
end

# Fixed numeric position of satellite B at t = 60 min (no gradient tracked).
const R_B_KM = begin
    epoch = SatelliteToolboxSgp4.tle_epoch(TLE_B)
    d = SatelliteToolboxSgp4.sgp4_init(
        epoch,
        TLE_B.mean_motion          * REV_DAY_TO_RAD_MIN,
        TLE_B.eccentricity,
        TLE_B.inclination          * D2R,
        TLE_B.raan                 * D2R,
        TLE_B.argument_of_perigee  * D2R,
        TLE_B.mean_anomaly         * D2R,
        TLE_B.bstar,
    )
    r, _ = SatelliteToolboxSgp4.sgp4!(d, 60.0)
    [r[1], r[2], r[3]]
end

# x = [n0, e0, i0, raan0, argp0, M0, bstar] for satellite A, at t = 60 min.
function propagate_a(x::AbstractVector{T}) where {T}
    epoch = SatelliteToolboxSgp4.tle_epoch(TLE_A)
    d = SatelliteToolboxSgp4.sgp4_init(
        epoch, x[1], x[2], x[3], x[4], x[5], x[6], x[7],
    )
    r, _ = SatelliteToolboxSgp4.sgp4!(d, T(60.0))
    return [r[1], r[2], r[3]]
end

const X0 = [
    TLE_A.mean_motion          * REV_DAY_TO_RAD_MIN,
    TLE_A.eccentricity,
    TLE_A.inclination          * D2R,
    TLE_A.raan                 * D2R,
    TLE_A.argument_of_perigee  * D2R,
    TLE_A.mean_anomaly         * D2R,
    TLE_A.bstar,
]
const PARAM_NAMES = ["n0", "e0", "i0", "raan0", "argp0", "M0", "bstar"]

# Closest distance from Earth's center to the line segment r_A–r_B, used for
# the analytic occlusion test: if this distance < Earth radius AND the
# closest point lies between the two endpoints, the segment is blocked.
function segment_earth_clearance_km(r_a::AbstractVector{T}, r_b::AbstractVector{<:Real}) where {T}
    d  = r_b .- r_a
    dd = dot(d, d)
    # Hard branch on dd ~ 0 only protects against a degenerate fixture (r_a==r_b);
    # it is not exercised by any θ derivative path below.
    s  = dd < 1e-9 ? T(0.0) : -dot(r_a, d) / dd
    s_clamped = clamp(s, T(0.0), T(1.0))
    closest = r_a .+ s_clamped .* d
    return norm(closest)
end

# ---------------------------------------------------------------------------
# Stage 1: distance_km = ||r_A - r_B||
# ---------------------------------------------------------------------------
@testset "Stage 1: theta -> distance_km" begin
    f = x -> [norm(propagate_a(x) .- R_B_KM)]
    J_ad = ForwardDiff.jacobian(f, X0)
    J_fd = fd_jacobian(f, X0)
    max_rel_err = maximum(
        abs(J_ad[1, j] - J_fd[1, j]) / (abs(J_fd[1, j]) + 1e-12) for j in 1:7
    )
    println("  distance_km = ", f(X0)[1], " km")
    for j in 1:7
        @printf("    d(distance)/d(%s)  AD=%.6e  FD=%.6e\n", PARAM_NAMES[j], J_ad[1,j], J_fd[1,j])
    end
    @printf("  max relative error: %.2e\n", max_rel_err)
    @test !any(isnan, J_ad)
    @test !any(isinf, J_ad)
    @test max_rel_err < 1e-3
end

# ---------------------------------------------------------------------------
# Stage 2: propagation_delay_s = distance_km / c
# ---------------------------------------------------------------------------
@testset "Stage 2: distance_km -> propagation_delay_s" begin
    f = x -> [norm(propagate_a(x) .- R_B_KM) / SPEED_OF_LIGHT_KM_S]
    J_ad = ForwardDiff.jacobian(f, X0)
    J_fd = fd_jacobian(f, X0)
    max_rel_err = maximum(
        abs(J_ad[1, j] - J_fd[1, j]) / (abs(J_fd[1, j]) + 1e-12) for j in 1:7
    )
    @printf("  propagation_delay_s = %.6e s\n", f(X0)[1])
    @printf("  max relative error: %.2e\n", max_rel_err)
    @test !any(isnan, J_ad)
    @test !any(isinf, J_ad)
    @test max_rel_err < 1e-3
end

# ---------------------------------------------------------------------------
# Stage 3a: HARD occlusion check (the actual yes/no test) — expected to be
#            a non-differentiable step function w.r.t. theta near the boundary.
#            We do NOT differentiate this; we just report its value to know
#            whether the fixture is even near the line-of-sight boundary.
# ---------------------------------------------------------------------------
clearance0 = segment_earth_clearance_km(propagate_a(X0), R_B_KM)
hard_los0  = clearance0 >= WGS84_EQUATORIAL_RADIUS_KM
println("  [Stage 3a] clearance_km = ", clearance0,
        "  earth_radius_km = ", WGS84_EQUATORIAL_RADIUS_KM,
        "  hard_line_of_sight = ", hard_los0)

# ---------------------------------------------------------------------------
# Stage 3b: SOFT occlusion proxy — visibility_score in (0,1), built from the
#            same smooth_sigmoid shape already used in
#            optimization_layer/differentiable.jl, applied to the margin
#            (clearance_km - earth_radius_km). This is the candidate
#            differentiable replacement for the hard line_of_sight boolean.
# ---------------------------------------------------------------------------
smooth_sigmoid(x::Real; beta::Real = 0.05) = 1.0 / (1.0 + exp(-beta * x))  # beta scaled for km-magnitude margins

@testset "Stage 3b: theta -> visibility_score (smooth occlusion proxy)" begin
    f = x -> begin
        margin = segment_earth_clearance_km(propagate_a(x), R_B_KM) - WGS84_EQUATORIAL_RADIUS_KM
        [smooth_sigmoid(margin)]
    end
    J_ad = ForwardDiff.jacobian(f, X0)
    J_fd = fd_jacobian(f, X0)
    max_rel_err = maximum(
        abs(J_ad[1, j] - J_fd[1, j]) / (abs(J_fd[1, j]) + 1e-9) for j in 1:7
    )
    @printf("  visibility_score = %.6f  (margin = %.3f km)\n", f(X0)[1], clearance0 - WGS84_EQUATORIAL_RADIUS_KM)
    for j in 1:7
        @printf("    d(visibility)/d(%s)  AD=%.6e  FD=%.6e\n", PARAM_NAMES[j], J_ad[1,j], J_fd[1,j])
    end
    @printf("  max relative error: %.2e\n", max_rel_err)
    @test !any(isnan, J_ad)
    @test !any(isinf, J_ad)
    @test max_rel_err < 1e-2   # looser tolerance: sigmoid derivative is small/flat far from boundary, FD noise relatively larger
end

println("\nProbe complete: theta -> distance_km -> propagation_delay_s -> visibility_score is gradient-transparent.")

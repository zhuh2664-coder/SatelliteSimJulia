# Test environment: test/Project.toml has SatelliteToolboxSgp4 + ForwardDiff.
# Run with: julia --project=test test/test_sgp4_differentiability.jl
import Pkg
Pkg.activate(@__DIR__; io = devnull)

using Test
using Printf
import ForwardDiff
import SatelliteToolboxSgp4
import LinearAlgebra: norm

# ---------------------------------------------------------------------------
# Unit conversion constants (TLE stores angles in deg, motion in rev/day;
# sgp4_init expects radians and rad/min)
# ---------------------------------------------------------------------------
const D2R             = π / 180
const REV_DAY_TO_RAD_MIN = 2π / (24 * 60)

# ---------------------------------------------------------------------------
# Fixture TLE  (VANGUARD 1 — classic test case used by SatelliteToolbox)
# ---------------------------------------------------------------------------
const TLE_LINE1 = "1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753"
const TLE_LINE2 = "2 00005  34.2682 331.5174 1859667 331.7664  19.3264 10.82419157413667"

const TLE_BASE = SatelliteToolboxSgp4.read_tle(TLE_LINE1, TLE_LINE2; verify_checksum = false)

# ---------------------------------------------------------------------------
# Helper: central finite-difference Jacobian for cross-checking AD
# ---------------------------------------------------------------------------
function fd_jacobian(f, x::AbstractVector{Float64}; h = 1e-6)
    y0 = f(x)
    n  = length(x)
    m  = length(y0)
    J  = zeros(m, n)
    for i in 1:n
        xp = copy(x); xp[i] += h
        xm = copy(x); xm[i] -= h
        J[:, i] = (f(xp) .- f(xm)) ./ (2h)
    end
    return J
end

# ---------------------------------------------------------------------------
# 1.  Scalar gradient: ∂|r|/∂t through the sgp4! call
# ---------------------------------------------------------------------------
@testset "AD transparency: ∂|r|/∂t" begin
    tle = TLE_BASE
    t0  = 60.0   # minutes after epoch

    # The propagator's numeric type T must match the Dual type used for t.
    # Cast all orbital elements to typeof(t_val) so sgp4_init produces
    # Sgp4Propagator{Float64, Dual} instead of Sgp4Propagator{Float64, Float64}.
    pos_norm = t_vec -> begin
        t_val = t_vec[1]
        T     = typeof(t_val)
        epoch = SatelliteToolboxSgp4.tle_epoch(tle)
        d = SatelliteToolboxSgp4.sgp4_init(
            epoch,
            T(tle.mean_motion         * REV_DAY_TO_RAD_MIN),
            T(tle.eccentricity),
            T(tle.inclination         * D2R),
            T(tle.raan                * D2R),
            T(tle.argument_of_perigee * D2R),
            T(tle.mean_anomaly        * D2R),
            T(tle.bstar),
        )
        r, _ = SatelliteToolboxSgp4.sgp4!(d, t_val)
        return [sqrt(r[1]^2 + r[2]^2 + r[3]^2)]
    end

    grad_ad = ForwardDiff.jacobian(pos_norm, [t0])
    grad_fd = fd_jacobian(pos_norm, [t0])

    rel_err = abs(grad_ad[1] - grad_fd[1]) / (abs(grad_fd[1]) + 1e-12)
    @printf("  ∂|r|/∂t  AD = %.6e   FD = %.6e   rel_err = %.2e\n",
            grad_ad[1], grad_fd[1], rel_err)

    @test !isnan(grad_ad[1])
    @test !isinf(grad_ad[1])
    @test rel_err < 1e-4
end

# ---------------------------------------------------------------------------
# 2.  Jacobian: TLE orbital elements → propagated position vector
#     x = [n₀ (rad/min), e₀, i₀ (rad), Ω₀ (rad), ω₀ (rad), M₀ (rad), bstar]
# ---------------------------------------------------------------------------
@testset "ForwardDiff Jacobian: TLE params → position" begin
    tle = TLE_BASE

    function propagate_from_params(x::AbstractVector{T}) where T
        epoch = SatelliteToolboxSgp4.tle_epoch(tle)
        d = SatelliteToolboxSgp4.sgp4_init(
            epoch,
            x[1],   # n₀  [rad/min]
            x[2],   # e₀
            x[3],   # i₀  [rad]
            x[4],   # Ω₀  [rad]
            x[5],   # ω₀  [rad]
            x[6],   # M₀  [rad]
            x[7],   # bstar
        )
        r, _ = SatelliteToolboxSgp4.sgp4!(d, T(60.0))
        return [r[1], r[2], r[3]]
    end

    # Convert TLE fields to the units sgp4_init expects
    x0 = [
        tle.mean_motion          * REV_DAY_TO_RAD_MIN,
        tle.eccentricity,
        tle.inclination          * D2R,
        tle.raan                 * D2R,
        tle.argument_of_perigee  * D2R,
        tle.mean_anomaly         * D2R,
        tle.bstar,
    ]

    J_ad = ForwardDiff.jacobian(propagate_from_params, x0)
    J_fd = fd_jacobian(propagate_from_params, x0)

    max_rel_err = maximum(
        abs(J_ad[i, j] - J_fd[i, j]) / (abs(J_fd[i, j]) + 1e-12)
        for i in 1:3, j in 1:7
    )

    param_names = ["n₀", "e₀", "i₀", "Ω₀", "ω₀", "M₀", "bstar"]
    println("  Jacobian ∂r/∂θ  (AD vs FD, t=60 min):")
    for j in 1:7
        @printf("    ∂r/∂%s  AD=[%10.3e %10.3e %10.3e]  FD=[%10.3e %10.3e %10.3e]\n",
                param_names[j],
                J_ad[1,j], J_ad[2,j], J_ad[3,j],
                J_fd[1,j], J_fd[2,j], J_fd[3,j])
    end
    @printf("  max relative error across all entries: %.2e\n", max_rel_err)

    @test !any(isnan, J_ad)
    @test !any(isinf, J_ad)
    @test max_rel_err < 1e-4
end

println("\nAll SGP4 differentiability tests passed.")

# SGP4 bidirectionality test
# Verifies: can sgp4!() be called at arbitrary time points (forward and backward)?
# Run with: julia --project=test test/test_sgp4_bidirectional.jl

import Pkg
Pkg.activate(@__DIR__; io = devnull)

using Test
using Printf
import SatelliteToolboxSgp4
import LinearAlgebra: norm

const D2R = π / 180
const REV_DAY_TO_RAD_MIN = 2π / (24 * 60)

# VANGUARD 1 TLE
const TLE_LINE1 = "1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753"
const TLE_LINE2 = "2 00005  34.2682 331.5174 1859667 331.7664  19.3264 10.82419157413667"

const TLE = SatelliteToolboxSgp4.read_tle(TLE_LINE1, TLE_LINE2; verify_checksum = false)

# Test 1: Same propagator, different time queries — no state corruption
@testset "Propagator state independence" begin
    epoch = SatelliteToolboxSgp4.tle_epoch(TLE)
    d = SatelliteToolboxSgp4.sgp4_init(
        epoch,
        TLE.mean_motion          * REV_DAY_TO_RAD_MIN,
        TLE.eccentricity,
        TLE.inclination          * D2R,
        TLE.raan                 * D2R,
        TLE.argument_of_perigee  * D2R,
        TLE.mean_anomaly         * D2R,
        TLE.bstar,
    )

    # Query forward to t=60
    r_fwd, v_fwd = SatelliteToolboxSgp4.sgp4!(d, 60.0)
    r1 = [r_fwd[1], r_fwd[2], r_fwd[3]]

    # Same propagator, query backward to t=0 (epoch)
    r_bwd, v_bwd = SatelliteToolboxSgp4.sgp4!(d, 0.0)
    r0 = [r_bwd[1], r_bwd[2], r_bwd[3]]

    # Same propagator, query forward again to t=60
    r_fwd2, v_fwd2 = SatelliteToolboxSgp4.sgp4!(d, 60.0)
    r1_prime = [r_fwd2[1], r_fwd2[2], r_fwd2[3]]

    diff = norm(r1 - r1_prime)
    @printf("Position at t=60 (first call):   [%.6f, %.6f, %.6f]\n", r1[1], r1[2], r1[3])
    @printf("Position at t=0 (backward call): [%.6f, %.6f, %.6f]\n", r0[1], r0[2], r0[3])
    @printf("Position at t=60 (second call):  [%.6f, %.6f, %.6f]\n", r1_prime[1], r1_prime[2], r1_prime[3])
    @printf("Difference between two t=60 calls: %.2e km\n", diff)

    @test diff < 1e-10
    @test all(isfinite, r0)
    @test all(isfinite, r1)
    @test all(isfinite, r1_prime)
end

# Test 2: Forward then backward in time on the same propagator
@testset "Forward-backward round trip" begin
    epoch = SatelliteToolboxSgp4.tle_epoch(TLE)
    d = SatelliteToolboxSgp4.sgp4_init(
        epoch,
        TLE.mean_motion          * REV_DAY_TO_RAD_MIN,
        TLE.eccentricity,
        TLE.inclination          * D2R,
        TLE.raan                 * D2R,
        TLE.argument_of_perigee  * D2R,
        TLE.mean_anomaly         * D2R,
        TLE.bstar,
    )

    # Forward: epoch -> t=100
    t_target = 100.0
    r_fwd, _ = SatelliteToolboxSgp4.sgp4!(d, t_target)
    pos_fwd = [r_fwd[1], r_fwd[2], r_fwd[3]]

    # Backward: t=100 -> t=50 on same propagator
    r_mid, _ = SatelliteToolboxSgp4.sgp4!(d, 50.0)
    pos_mid = [r_mid[1], r_mid[2], r_mid[3]]

    # Forward again: t=50 -> t=100 (different route, same end)
    r_fwd_again, _ = SatelliteToolboxSgp4.sgp4!(d, t_target)
    pos_fwd_again = [r_fwd_again[1], r_fwd_again[2], r_fwd_again[3]]

    @printf("pos_fwd       @ t=100: [%.6f, %.6f, %.6f]\n", pos_fwd[1], pos_fwd[2], pos_fwd[3])
    @printf("pos_mid       @ t=50:  [%.6f, %.6f, %.6f]\n", pos_mid[1], pos_mid[2], pos_mid[3])
    @printf("pos_fwd_again @ t=100: [%.6f, %.6f, %.6f]\n", pos_fwd_again[1], pos_fwd_again[2], pos_fwd_again[3])

    diff_roundtrip = norm(pos_fwd - pos_fwd_again)
    @printf("Round-trip difference: %.2e km\n", diff_roundtrip)
    @test diff_roundtrip < 1e-10
    @test all(isfinite, pos_mid)
end

# Test 3: Arbitrary time ordering — non-monotonic queries
@testset "Non-monotonic time queries" begin
    epoch = SatelliteToolboxSgp4.tle_epoch(TLE)
    d = SatelliteToolboxSgp4.sgp4_init(
        epoch,
        TLE.mean_motion          * REV_DAY_TO_RAD_MIN,
        TLE.eccentricity,
        TLE.inclination          * D2R,
        TLE.raan                 * D2R,
        TLE.argument_of_perigee  * D2R,
        TLE.mean_anomaly         * D2R,
        TLE.bstar,
    )

    # Query in wild order: 80, 20, 60, 40, 100
    times = [80.0, 20.0, 60.0, 40.0, 100.0]
    positions = []
    for t in times
        r, _ = SatelliteToolboxSgp4.sgp4!(d, t)
        push!(positions, [r[1], r[2], r[3]])
    end

    @printf("Positions from non-monotonic queries:\n")
    for (i, t) in enumerate(times)
        @printf("  t=%6.1f  [%.6f, %.6f, %.6f]\n", t, positions[i][1], positions[i][2], positions[i][3])
    end

    # Verify each position is finite and non-zero
    for (i, pos) in enumerate(positions)
        @test all(isfinite, pos)
        @test norm(pos) > 1.0  # reasonable earth orbit distance
    end

    # Now verify that querying t=60 directly after the wild sequence
    # gives the SAME result as querying t=60 in the wild sequence
    r_direct, _ = SatelliteToolboxSgp4.sgp4!(d, 60.0)
    pos_direct = [r_direct[1], r_direct[2], r_direct[3]]
    pos_wild_60 = positions[3]  # third query was t=60
    diff_between_60s = norm(pos_direct - pos_wild_60)
    @printf("Difference between two t=60 positions: %.2e km\n", diff_between_60s)
    @test diff_between_60s < 1e-10
end

println("\n✓ SGP4 propagator supports arbitrary (non-sequential, bidirectional) time queries.")
println("  The propagator state is NOT destructively modified by sgp4!() calls.")
println("  This means: calling sgp4!(d, t2) after sgp4!(d, t1) with any t1, t2 order is safe.")
println("  Implication for SciML adjoint: trajectory can be reconstructed at any time point,")
println("  no checkpointing needed.")

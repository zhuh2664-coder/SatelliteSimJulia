# =============================================================================
# Tests for end-to-end differentiable SGP4 → coverage loss gradient
# =============================================================================
# Engines under test:
#   :enzyme    — whole-chain reverse (main engine)
#   :blockdiag — custom loss adjoint + per-satellite ForwardDiff Jacobians
# Both are compared against full-vector ForwardDiff and central differences.

using Test
using Random
using LinearAlgebra: norm, dot
using ForwardDiff
using SatelliteToolbox
using SatelliteToolboxSgp4
using SatelliteSimFoundation: SimulationEpoch, SimulationTimeGrid,
                              default_starlink_simulation_epoch,
                              julian_day, timeslot_offsets
using SatelliteSimOrbit: TLEOrbitElementSet, propagate_to_ecef
import SatelliteSimOpt
using SatelliteSimOpt: sgp4_constellation_series, sgp4_series_ecef,
                       coverage_loss_vjp, sgp4_e2e_gradient,
                       coverage_loss, ground_grid, soft_coverage, logsumexp_max

const SGP4_D2R = π / 180
const SGP4_REV_DAY_TO_RAD_MIN = 2π / (24 * 60)
const SGP4_TLE_PATH = joinpath(@__DIR__, "..", "..", "..",
                               "data", "tle", "celestrak", "starlink_gp_latest.tle")

function read_starlink_params_epochs(n::Int)
    lines = readlines(SGP4_TLE_PATH)
    tles = SatelliteToolboxSgp4.TLE[]
    for i in 1:n
        l1 = strip(lines[3i - 1])
        l2 = strip(lines[3i])
        push!(tles, SatelliteToolboxSgp4.read_tle(l1, l2; verify_checksum=false))
    end
    epochs = Float64[SatelliteToolboxSgp4.tle_epoch(t) for t in tles]
    params = Float64[]
    for t in tles
        append!(params, (
            t.mean_motion * SGP4_REV_DAY_TO_RAD_MIN,
            t.eccentricity,
            t.inclination * SGP4_D2R,
            t.raan * SGP4_D2R,
            t.argument_of_perigee * SGP4_D2R,
            t.mean_anomaly * SGP4_D2R,
            t.bstar,
        ))
    end
    return params, epochs
end

@testset "SGP4 end-to-end differentiable chain" begin

# ── coverage relaxation Dual regression (non-default min_el/τ) ────────────────
@testset "soft relaxation tokens accept Dual with non-default kwargs" begin
    g = ForwardDiff.derivative(15.0) do el
        soft_coverage(el, oftype(el, 12.5); τ = oftype(el, 2.0))
    end
    @test isfinite(g) && g > 0

    g2 = ForwardDiff.gradient([1.0, 2.0, 3.0]) do v
        logsumexp_max(v; τ = eltype(v)(0.7))
    end
    @test all(isfinite, g2)
    @test sum(g2) ≈ 1.0 atol=1e-12   # LSE softmax weights sum to 1
end

# ── domain validation & SDP4 rejection ────────────────────────────────────────
@testset "parameter domain validation" begin
    params, epochs = read_starlink_params_epochs(2)
    ts = [0.0, 10.0]
    jd_ref = maximum(epochs)

    # Deep-space period: n₀ = 2π/226 rad/min → period 226 min ≥ 225 min limit
    bad = copy(params); bad[1] = 2π / 226.0
    @test_throws ArgumentError sgp4_constellation_series(bad, epochs, ts; jd_ref=jd_ref)

    bad_e = copy(params); bad_e[2] = 1.5
    @test_throws ArgumentError sgp4_constellation_series(bad_e, epochs, ts; jd_ref=jd_ref)

    bad_b = copy(params); bad_b[7] = 2.0
    @test_throws ArgumentError sgp4_constellation_series(bad_b, epochs, ts; jd_ref=jd_ref)

    bad_len = params[1:13]
    @test_throws ArgumentError sgp4_constellation_series(bad_len, epochs, ts; jd_ref=jd_ref)
end

# ── formal series API: exports, shapes, and CPU Orbit-path parity ─────────────
@testset "formal series API matches Orbit SGP4 path" begin
    @test :sgp4_constellation_series in names(SatelliteSimOpt)
    @test :sgp4_series_ecef in names(SatelliteSimOpt)

    N = 2
    params, epochs = read_starlink_params_epochs(N)
    lines = readlines(SGP4_TLE_PATH)
    tle_specs = TLEOrbitElementSet[
        TLEOrbitElementSet(
            strip(lines[3i - 2]),
            strip(lines[3i - 1]),
            strip(lines[3i]),
        )
        for i in 1:N
    ]

    first_tle = SatelliteToolboxSgp4.read_tle(
        tle_specs[1].line1, tle_specs[1].line2; verify_checksum=false,
    )
    date_type = typeof(default_starlink_simulation_epoch().instant)
    epoch_dt = SatelliteToolbox.tle_epoch(date_type, first_tle)
    grid = SimulationTimeGrid(SimulationEpoch(epoch_dt), 1200, 600)
    ts_min = Float64.(timeslot_offsets(grid)) ./ 60
    jd_ref = julian_day(epoch_dt)
    gmsts = Float64[
        SatelliteToolbox.jd_to_gmst(jd_ref + t / 1440.0) for t in ts_min
    ]

    positions_teme = sgp4_constellation_series(
        params, epochs, ts_min; jd_ref=jd_ref,
    )
    positions_ecef = sgp4_series_ecef(
        params, epochs, ts_min, gmsts; jd_ref=jd_ref,
    )
    orbit_ecef = propagate_to_ecef(tle_specs, grid; verify_checksum=false)

    @test size(positions_teme) == (N, length(ts_min), 3)
    @test size(positions_ecef) == size(orbit_ecef)
    @test eltype(positions_teme) == Float64
    @test all(isfinite, positions_teme)
    @test all(isfinite, positions_ecef)
    # Separate but equivalent wall-clock and TEME→PEF implementations differ
    # only by Float64 Julian-date rounding; 1e-4 km is a 10 cm bound.
    @test maximum(abs.(positions_ecef .- orbit_ecef)) < 1e-4
end

# ── direct ForwardDiff vs central FD through both public series APIs ─────────
@testset "series API ForwardDiff gradient matches finite differences" begin
    params, epochs = read_starlink_params_epochs(1)
    ts_min = [0.0, 30.0, 60.0, 90.0]
    jd_ref = epochs[1] + 0.25
    gmsts = Float64[
        SatelliteToolbox.jd_to_gmst(jd_ref + t / 1440.0) for t in ts_min
    ]
    weights = reshape(collect(1.0:12.0) ./ 12, 1, length(ts_min), 3)
    reverse_weights = reverse(weights; dims=3)

    teme_probe(p) = sum(
        sgp4_constellation_series(
            p, epochs, ts_min; jd_ref=jd_ref,
        ) .* weights,
    )
    ecef_probe(p) = sum(
        sgp4_series_ecef(
            p, epochs, ts_min, gmsts; jd_ref=jd_ref,
        ) .* reverse_weights,
    )

    for (name, probe) in (("TEME", teme_probe), ("ECEF", ecef_probe))
        @testset "$name series" begin
            grad_ad = ForwardDiff.gradient(probe, params)
            @test all(isfinite, grad_ad)
            @test all(!iszero, grad_ad)

            grad_scale = maximum(abs, grad_ad)
            for idx in eachindex(params)
                h0 = 1e-6 * max(abs(params[idx]), 1e-2)
                best_rel = Inf
                for scale in (0.1, 1.0, 10.0)
                    h = scale * h0
                    xp = copy(params)
                    xm = copy(params)
                    xp[idx] += h
                    xm[idx] -= h
                    grad_fd = (probe(xp) - probe(xm)) / (2h)
                    rel = abs(grad_ad[idx] - grad_fd) /
                          (abs(grad_fd) + 1e-10 * grad_scale)
                    best_rel = min(best_rel, rel)
                end
                @test best_rel < 1e-5
            end
        end
    end
end

# ── adjoint vs ForwardDiff-on-positions (small fixture) ───────────────────────
@testset "coverage_loss_vjp matches ForwardDiff on positions" begin
    Random.seed!(7)
    N, NT, G = 6, 4, 20
    positions = Array{Float64}(undef, N, NT, 3)
    for i in 1:N, t in 1:NT
        positions[i, t, 1] = 7000.0 + 200.0 * randn()
        positions[i, t, 2] = 7000.0 + 200.0 * randn()
        positions[i, t, 3] = 1000.0 + 200.0 * randn()
    end
    gp, w = ground_grid(4, 5)

    loss_ref = coverage_loss(positions, gp, w;
                             min_el=10.0, τ_cov=5.0, dt=1.0, τ_revisit=1.0, λ=0.1)
    loss_vjp, dP = coverage_loss_vjp(positions, gp, w;
                                     min_el=10.0, τ_cov=5.0, dt=1.0, τ_revisit=1.0, λ=0.1)
    @test loss_ref ≈ loss_vjp rtol=1e-12

    function loss_from_flatP(flatP)
        P = reshape(flatP, N, NT, 3)
        T = eltype(P)
        return coverage_loss(P, T.(gp), T.(w);
                             min_el=T(10.0), τ_cov=T(5.0), dt=T(1.0),
                             τ_revisit=T(1.0), λ=T(0.1))
    end
    dP_fd = reshape(ForwardDiff.gradient(loss_from_flatP, vec(positions)), N, NT, 3)
    @test dP ≈ dP_fd rtol=1e-10
end

# ── end-to-end gradient vs full ForwardDiff + FD on 10 real TLEs ─────────────
@testset "sgp4_e2e_gradient vs full ForwardDiff (N=10, both engines)" begin
    N = 10
    NT = 10
    params0, epochs = read_starlink_params_epochs(N)
    jd_ref = maximum(epochs)
    ts_min = collect(range(0.0, 95.0; length=NT))
    dt_grid = ts_min[2] - ts_min[1]
    gmsts = Float64[SatelliteToolbox.jd_to_gmst(jd_ref + t / 1440.0) for t in ts_min]
    gp, w = ground_grid(5, 10)

    loss_enz, grad_enz = sgp4_e2e_gradient(params0, epochs, ts_min, gp, w;
                                           jd_ref=jd_ref, gmsts=gmsts,
                                           engine=:enzyme, dt=dt_grid)
    loss_bd, grad_bd = sgp4_e2e_gradient(params0, epochs, ts_min, gp, w;
                                         jd_ref=jd_ref, gmsts=gmsts,
                                         engine=:blockdiag, dt=dt_grid)

    function loss_from_params(p)
        T = eltype(p)
        pos = sgp4_series_ecef(p, epochs, ts_min, T.(gmsts); jd_ref=jd_ref)
        return coverage_loss(pos, T.(gp), T.(w);
                             min_el=T(10.0), τ_cov=T(5.0), dt=T(dt_grid),
                             τ_revisit=T(1.0), λ=T(0.1))
    end
    loss_ref = loss_from_params(params0)
    grad_ref = ForwardDiff.gradient(loss_from_params, params0)

    @test loss_enz ≈ loss_ref rtol=1e-12
    @test loss_bd ≈ loss_ref rtol=1e-12
    @test all(isfinite, grad_enz) && all(isfinite, grad_bd)

    # Main acceptance: relative L2 and per-component vs full ForwardDiff < 1e-8
    @test norm(grad_enz - grad_ref) / norm(grad_ref) < 1e-8
    @test norm(grad_bd - grad_ref) / norm(grad_ref) < 1e-8
    gmax = maximum(abs, grad_ref)
    @test maximum(abs.(grad_enz .- grad_ref) ./ (abs.(grad_ref) .+ 1e-10 * gmax)) < 1e-8
    @test maximum(abs.(grad_bd .- grad_ref) ./ (abs.(grad_ref) .+ 1e-10 * gmax)) < 1e-8

    # ── central differences: ≥10 components, step scan h×{0.1, 1, 10} ────────
    Random.seed!(42)
    idxs = randperm(length(params0))[1:10]
    for idx in idxs
        h0 = 1e-6 * max(abs(params0[idx]), 1e-2)
        best_rel = Inf
        for scale in (0.1, 1.0, 10.0)
            h = scale * h0
            xp = copy(params0); xm = copy(params0)
            xp[idx] += h; xm[idx] -= h
            fp = loss_from_params(xp)
            fm = loss_from_params(xm)
            @test isfinite(fp) && isfinite(fm)
            g_fd = (fp - fm) / (2h)
            rel = abs(grad_enz[idx] - g_fd) / (abs(g_fd) + 1e-10 * gmax)
            best_rel = min(best_rel, rel)
        end
        # Central differences are O(h²); accept the best step of the scan.
        @test best_rel < 1e-4
    end

    # ── random directional derivative check ──────────────────────────────────
    Random.seed!(43)
    v = randn(length(params0))
    v ./= norm(v)
    # Scale each component relative to parameter magnitude to keep SGP4 stable.
    scale_vec = max.(abs.(params0), 1e-2)
    dir = v .* scale_vec
    hs = 1e-6
    fp = loss_from_params(params0 .+ hs .* dir)
    fm = loss_from_params(params0 .- hs .* dir)
    @test isfinite(fp) && isfinite(fm)
    dd_fd = (fp - fm) / (2hs)
    dd_ad = dot(grad_enz, dir)
    @test abs(dd_ad - dd_fd) / (abs(dd_fd) + 1e-12) < 1e-5
end

end # outer testset

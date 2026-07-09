# Phase 4 orbit alignment: GMAT Kepler must match Orbit TwoBody with true RV

using Test
using SatelliteSimJulia
using GMAT
using LinearAlgebra
using Statistics

@testset "GMAT Kepler vs Orbit TwoBody (true initial RV)" begin
    els = generate_walker_delta(T=1, P=1, F=0, alt_km=780.0, inc_deg=0.0)
    tspan = collect(0.0:60.0:600.0)
    pos, vel = propagate_eci_rv(els, tspan; propagator=:two_body)
    r0 = pos[1, 1, :]
    v0 = vel[1, 1, :]

    # Pitfall: circular √(μ/a) with a=R⊕+alt (not |r|) + wrong direction
    # produces O(km) false disagreement; always take v from propagate_eci_rv.
    μ = 3.986004418e14
    a_nominal = 6378.137e3 + 780e3
    v_wrong = [-r0[2], r0[1], 0.0]
    v_wrong .*= sqrt(μ / a_nominal) / norm(v_wrong)
    @test norm(v0 .- v_wrong) > 1.0  # m/s — enough to matter over minutes

    setup = PropSetup(
        force_model=combine_forces(GravityField(degree=0)),
        integrator=PrinceDormand78(),
        spacecraft=Spacecraft(),
    )
    sol = propagate(setup, vcat(r0, v0), tspan)
    errs = [norm(sol.u[k][1:3] .- pos[1, k, :]) for k in eachindex(tspan)]
    @test maximum(errs) < 1.0  # sub-meter over 10 minutes
    @test mean(errs) < 0.5
end
